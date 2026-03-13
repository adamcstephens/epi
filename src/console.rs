use anyhow::{Context, Result, bail};
use crossterm::event::{self, Event, KeyCode, KeyEvent, KeyModifiers};
use crossterm::terminal;
use std::fs::{self, File};
use std::io::{IsTerminal, Read, Write};
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
    let mut ctrl_t_pressed = false;

    loop {
        if let Some(dl) = deadline {
            if Instant::now() >= dl {
                eprintln!("\nconsole timeout reached");
                break;
            }
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

        // Read from stdin via crossterm events
        if read_stdin && event::poll(Duration::from_millis(0))? {
            if let Event::Key(key) = event::read()? {
                if ctrl_t_pressed && matches!(key.code, KeyCode::Char('q') | KeyCode::Char('Q')) {
                    eprintln!("\ndetached");
                    return Ok(());
                }
                ctrl_t_pressed =
                    key.code == KeyCode::Char('t') && key.modifiers.contains(KeyModifiers::CONTROL);

                // Forward the keypress to the socket
                if let Some(bytes) = key_to_bytes(&key) {
                    stream.set_nonblocking(false)?;
                    stream.write_all(&bytes)?;
                    stream.set_nonblocking(true)?;
                }
            }
        }

        std::thread::sleep(Duration::from_millis(10));
    }

    Ok(())
}

fn key_to_bytes(key: &KeyEvent) -> Option<Vec<u8>> {
    match key.code {
        KeyCode::Char(c) => {
            if key.modifiers.contains(KeyModifiers::CONTROL) {
                // Ctrl+letter → ASCII control char
                let ctrl = (c as u8).wrapping_sub(b'a').wrapping_add(1);
                Some(vec![ctrl])
            } else {
                let mut buf = [0u8; 4];
                let s = c.encode_utf8(&mut buf);
                Some(s.as_bytes().to_vec())
            }
        }
        KeyCode::Enter => Some(vec![b'\r']),
        KeyCode::Backspace => Some(vec![0x7f]),
        KeyCode::Tab => Some(vec![b'\t']),
        KeyCode::Esc => Some(vec![0x1b]),
        _ => None,
    }
}

/// RAII guard to disable raw mode on drop
struct RawModeGuard;

impl Drop for RawModeGuard {
    fn drop(&mut self) {
        let _ = terminal::disable_raw_mode();
    }
}

/// Start a background console capture thread
pub fn start_capture(instance_name: &str) -> Result<()> {
    let runtime = match instance_store::find_runtime(instance_name)? {
        Some(r) => r,
        None => return Ok(()),
    };

    if runtime.serial_socket.is_empty() {
        return Ok(());
    }

    let log_path = instance_store::console_log_path(instance_name);
    let socket_path = runtime.serial_socket.clone();

    std::thread::spawn(move || -> Result<()> {
        let mut stream = connect_socket(&socket_path, 60, Duration::from_secs(1))?;
        let mut file = File::create(&log_path)?;
        let mut buf = [0u8; 4096];
        loop {
            match stream.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    file.write_all(&buf[..n])?;
                    file.flush()?;
                }
                Err(e) => {
                    eprintln!("console capture error: {e}");
                    break;
                }
            }
        }
        Ok(())
    });

    Ok(())
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
