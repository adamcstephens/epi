use anyhow::{Context, Result, bail};
use crossterm::terminal;
use nix::fcntl::{FcntlArg, OFlag, fcntl};
use std::fs::{self, File};
use std::io::{IsTerminal, Read, Seek, Write};
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

    // Dump scrollback from console.log before connecting
    let console_log = instance_store::console_log_path(instance_name);
    let scrollback = read_scrollback(&console_log, SCROLLBACK_BYTES);
    if !scrollback.is_empty() {
        let cleaned = strip_control_chars(&scrollback);
        if !cleaned.is_empty() {
            eprintln!("--- scrollback (console.log) ---");
            eprint!("{cleaned}");
            if !cleaned.ends_with('\n') {
                eprintln!();
            }
            eprintln!("--- live ---");
        }
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

const SCROLLBACK_BYTES: usize = 8192;

/// Strip ANSI escape sequences and non-printable control characters from text.
/// Preserves newlines (0x0A) and carriage returns (0x0D).
fn strip_control_chars(input: &str) -> String {
    let stripped = fast_strip_ansi::strip_ansi_string(input);
    stripped
        .chars()
        .filter(|c| {
            let b = *c as u32;
            // Keep printable chars, newline, carriage return
            b >= 0x20 || b == 0x0A || b == 0x0D
        })
        .collect()
}

/// Read the last `max_bytes` of a file as a string.
/// Returns empty string if the file does not exist.
fn read_scrollback(path: &std::path::Path, max_bytes: usize) -> String {
    let file = match File::open(path) {
        Ok(f) => f,
        Err(_) => return String::new(),
    };
    let metadata = match file.metadata() {
        Ok(m) => m,
        Err(_) => return String::new(),
    };
    let file_len = metadata.len() as usize;
    let offset = file_len.saturating_sub(max_bytes);
    let mut reader = std::io::BufReader::new(file);
    if offset > 0 {
        if reader
            .seek(std::io::SeekFrom::Start(offset as u64))
            .is_err()
        {
            return String::new();
        }
    }
    let mut buf = String::new();
    if reader.read_to_string(&mut buf).is_err() {
        // File may contain non-UTF8; read as bytes and lossy-convert
        if let Ok(mut file) = File::open(path) {
            let mut bytes = Vec::new();
            if file.seek(std::io::SeekFrom::Start(offset as u64)).is_ok() {
                let _ = file.read_to_end(&mut bytes);
                return String::from_utf8_lossy(&bytes).into_owned();
            }
        }
        return String::new();
    }
    buf
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn strip_control_chars_removes_ansi_colors() {
        let input = "\x1b[32mOK\x1b[0m";
        assert_eq!(strip_control_chars(input), "OK");
    }

    #[test]
    fn strip_control_chars_removes_non_printable_preserves_newlines() {
        let input = "hello\x07\x08world\nfoo\rbar";
        assert_eq!(strip_control_chars(input), "helloworld\nfoo\rbar");
    }

    #[test]
    fn strip_control_chars_passes_through_plain_text() {
        let input = "just plain text\nwith lines\n";
        assert_eq!(strip_control_chars(input), input);
    }

    #[test]
    fn read_scrollback_reads_tail() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("test.log");
        let mut f = File::create(&path).unwrap();
        // Write 100 bytes of 'a' then 50 bytes of 'b'
        f.write_all(&[b'a'; 100]).unwrap();
        f.write_all(&[b'b'; 50]).unwrap();
        drop(f);

        let result = read_scrollback(&path, 50);
        assert_eq!(result.len(), 50);
        assert!(result.chars().all(|c| c == 'b'));
    }

    #[test]
    fn read_scrollback_returns_full_content_when_small() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("test.log");
        fs::write(&path, "small content").unwrap();

        let result = read_scrollback(&path, 8192);
        assert_eq!(result, "small content");
    }

    #[test]
    fn read_scrollback_returns_empty_for_missing_file() {
        let result = read_scrollback(std::path::Path::new("/nonexistent/path/file.log"), 8192);
        assert_eq!(result, "");
    }
}
