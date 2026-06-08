//! Serial console bridge for the VZ daemon.
//!
//! vfrust attaches the guest serial port to a host pty (master held by the
//! VM). This bridges that pty to the same surface cloud-hypervisor exposes on
//! Linux: every byte is teed to `console.log` for scrollback, and a unix
//! socket lets `epi console` attach interactively. Reusing the unix-socket
//! shape means the shared `console::attach` works unchanged on macOS.

use std::fs::OpenOptions;
use std::io::{Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::sync::{Arc, Mutex};

use anyhow::{Context, Result};

/// Put a tty/pty fd into raw mode (no echo, no line processing), so bytes
/// pass through untouched in both directions.
fn set_raw<F: std::os::fd::AsFd>(fd: &F) -> Result<()> {
    use nix::sys::termios::{SetArg, cfmakeraw, tcgetattr, tcsetattr};
    let mut termios = tcgetattr(fd).context("tcgetattr")?;
    cfmakeraw(&mut termios);
    tcsetattr(fd, SetArg::TCSANOW, &termios).context("tcsetattr")?;
    Ok(())
}

/// Start the serial bridge in background threads. Returns once the socket is
/// bound; the threads run until the pty closes (VM stop) or the process exits.
pub fn spawn_bridge(pty_path: &str, console_log: &Path, serial_sock: &Path) -> Result<()> {
    let pty_read = OpenOptions::new()
        .read(true)
        .write(true)
        .open(pty_path)
        .with_context(|| format!("opening serial pty {pty_path}"))?;

    // Force the pty fully raw. Without this, ECHO loops the guest's serial
    // *output* (which VZ writes to the master) back as serial *input*, and the
    // guest's getty drowns in "input overrun" during the boot-log flood.
    set_raw(&pty_read).context("setting serial pty to raw mode")?;

    let pty_write = pty_read.try_clone().context("cloning serial pty handle")?;

    let log = OpenOptions::new()
        .create(true)
        .append(true)
        .open(console_log)
        .with_context(|| format!("opening console log {}", console_log.display()))?;

    if serial_sock.exists() {
        std::fs::remove_file(serial_sock).context("removing stale serial socket")?;
    }
    let listener = UnixListener::bind(serial_sock)
        .with_context(|| format!("binding serial socket {}", serial_sock.display()))?;

    // Write halves of all attached clients. The pty reader fans guest output
    // out to each and drops any that error.
    let clients: Arc<Mutex<Vec<UnixStream>>> = Arc::new(Mutex::new(Vec::new()));

    // pty → console.log + every attached client
    {
        let clients = Arc::clone(&clients);
        let mut log = log;
        let mut pty_read = pty_read;
        std::thread::spawn(move || {
            let mut buf = [0u8; 4096];
            loop {
                match pty_read.read(&mut buf) {
                    Ok(0) | Err(_) => break, // master closed — VM stopped
                    Ok(n) => {
                        let data = &buf[..n];
                        let _ = log.write_all(data);
                        let _ = log.flush();
                        clients
                            .lock()
                            .unwrap()
                            .retain_mut(|c| c.write_all(data).is_ok());
                    }
                }
            }
        });
    }

    // Accept clients concurrently; each gets its own client → pty thread so a
    // lingering connection never blocks new attaches.
    {
        let clients = Arc::clone(&clients);
        std::thread::spawn(move || {
            for conn in listener.incoming() {
                let Ok(stream) = conn else { continue };
                let Ok(write_half) = stream.try_clone() else {
                    continue;
                };
                let Ok(mut pty) = pty_write.try_clone() else {
                    continue;
                };
                clients.lock().unwrap().push(write_half);

                let mut reader = stream;
                std::thread::spawn(move || {
                    let mut buf = [0u8; 4096];
                    loop {
                        match reader.read(&mut buf) {
                            Ok(0) | Err(_) => break,
                            Ok(n) => {
                                if pty.write_all(&buf[..n]).is_err() {
                                    break;
                                }
                            }
                        }
                    }
                });
            }
        });
    }

    Ok(())
}
