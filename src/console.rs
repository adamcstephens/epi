use anyhow::{Context, Result, bail};
use crossterm::terminal;
use nix::fcntl::{FcntlArg, OFlag, fcntl};
use std::fs::{self, File};
use std::io::{IsTerminal, Read, Write};
use std::os::fd::AsFd;
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

use crate::instance_store;

/// Connect to serial socket with retries
fn connect_socket(path: &str, retries: u32, interval: Duration) -> Result<UnixStream> {
    let mut last_err = None;
    for _ in 0..retries {
        match UnixStream::connect(path) {
            Ok(stream) => return Ok(stream),
            Err(e) => {
                last_err = Some(e);
                std::thread::sleep(interval);
            }
        }
    }
    bail!(
        "failed to connect to serial socket {path} after {retries} attempts: {}",
        last_err.expect("retries must be > 0")
    )
}

/// Attach to an instance's serial console interactively
pub fn attach(
    instance_name: &str,
    capture_path: Option<&str>,
    timeout_seconds: Option<f64>,
) -> Result<()> {
    let runtime = instance_store::find_runtime(instance_name)?
        .ok_or_else(|| anyhow::anyhow!("instance {instance_name} is not running"))?;

    if runtime.serial_socket.is_empty() {
        bail!("no serial socket for instance {instance_name}");
    }

    let mut stream = connect_socket(&runtime.serial_socket, 40, Duration::from_millis(50))?;
    stream.set_nonblocking(true)?;

    let is_tty = std::io::stdin().is_terminal();
    let read_stdin = is_tty;

    let mut capture_file = capture_path
        .map(|p| File::create(p).with_context(|| format!("creating capture file {p}")))
        .transpose()?;

    let deadline = timeout_seconds.map(|t| Instant::now() + Duration::from_secs_f64(t));

    if read_stdin {
        terminal::enable_raw_mode()?;
    }
    // Ensure raw mode is restored on any exit path
    let _raw_guard = if read_stdin { Some(RawModeGuard) } else { None };

    eprintln!("attached to console (Ctrl-T q to detach)");

    let mut sock_buf = [0u8; 4096];
    let mut stdin_buf = [0u8; 4096];
    let mut ctrl_t_pending = false;

    let mut stdin = std::io::stdin();
    if read_stdin {
        // Set stdin to non-blocking so we can poll it alongside the socket
        let stdin_flags = fcntl(stdin.as_fd(), FcntlArg::F_GETFL)?;
        let stdin_flags = OFlag::from_bits_retain(stdin_flags);
        fcntl(
            stdin.as_fd(),
            FcntlArg::F_SETFL(stdin_flags | OFlag::O_NONBLOCK),
        )?;
    }

    loop {
        if let Some(dl) = deadline
            && Instant::now() >= dl
        {
            eprintln!("\nconsole timeout reached");
            break;
        }

        // Read from socket
        match stream.read(&mut sock_buf) {
            Ok(0) => {
                eprintln!("\nconsole disconnected");
                break;
            }
            Ok(n) => {
                let data = &sock_buf[..n];
                std::io::stdout().write_all(data)?;
                std::io::stdout().flush()?;
                if let Some(ref mut f) = capture_file {
                    f.write_all(data)?;
                }
            }
            Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(e) => bail!("reading console: {e}"),
        }

        // Read raw bytes from stdin and forward to socket
        if read_stdin {
            match stdin.read(&mut stdin_buf) {
                Ok(0) => {}
                Ok(n) => {
                    let bytes = &stdin_buf[..n];
                    let mut i = 0;
                    while i < bytes.len() {
                        if ctrl_t_pending {
                            ctrl_t_pending = false;
                            if bytes[i] == b'q' || bytes[i] == b'Q' {
                                eprintln!("\ndetached");
                                return Ok(());
                            }
                            // Not q — forward the buffered Ctrl-T and this byte
                            stream.set_nonblocking(false)?;
                            stream.write_all(&[0x14])?;
                            stream.set_nonblocking(true)?;
                            // Fall through to forward bytes[i] normally
                        }

                        if bytes[i] == 0x14 {
                            // Ctrl-T: forward everything before it, then pend
                            ctrl_t_pending = true;
                            i += 1;
                            continue;
                        }

                        // Find the next Ctrl-T (or end) and forward the chunk
                        let start = i;
                        while i < bytes.len() && bytes[i] != 0x14 {
                            i += 1;
                        }
                        stream.set_nonblocking(false)?;
                        stream.write_all(&bytes[start..i])?;
                        stream.set_nonblocking(true)?;
                    }
                }
                Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(e) => bail!("reading stdin: {e}"),
            }
        }

        std::thread::sleep(Duration::from_millis(10));
    }

    Ok(())
}

/// RAII guard to disable raw mode on drop
struct RawModeGuard;

impl Drop for RawModeGuard {
    fn drop(&mut self) {
        let _ = terminal::disable_raw_mode();
    }
}

/// Show captured console log
pub fn show_log(instance_name: &str) -> Result<()> {
    let path = instance_store::console_log_path(instance_name);
    if !path.exists() {
        bail!("no console log for instance {instance_name}");
    }
    let content = fs::read_to_string(&path)?;
    print!("{content}");
    Ok(())
}
