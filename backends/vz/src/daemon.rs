//! Supervisor loop for the `epi __vmm-daemon` helper.
//!
//! Holds the `VmHandle`, serves the per-instance control socket, and
//! watches the VM state stream so the daemon exits when the guest stops.
//! Every termination path goes through `request_stop` → `stop` before the
//! `VirtualMachine` drops — vfrust's drop blocks for up to 7s otherwise.

use anyhow::{Context, Result};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::signal::unix::{SignalKind, signal};
use tokio::sync::watch;

use epi_core::backend::{InstanceStatus, LaunchSpec};
use epi_core::instance_store;
use vfrust::VmState;

use crate::control::{self, Request, Response};

/// Grace period for SIGTERM-initiated shutdown, matching the CLI default.
const SIGTERM_GRACE: Duration = Duration::from_secs(20);

const LAUNCH_SPEC_FILE: &str = "launch-spec.json";
const PID_FILE: &str = "daemon.pid";

/// Entrypoint for the hidden `epi __vmm-daemon <instance>` subcommand.
pub fn daemon_main(instance: &str) -> Result<()> {
    let instance_dir = instance_store::instance_dir(instance);
    let spec = read_launch_spec(&instance_dir)?;
    let config = crate::vm_config(&spec)?;

    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .with_context(|| format!("building vmm daemon runtime for {instance}"))?;
    runtime.block_on(async {
        // vfrust needs a live tokio reactor when the VM is created, so build
        // it inside the runtime. Keep `vm` bound across `supervise` — its
        // drop tears the VM down (after supervise has already stopped it).
        let vm = vfrust::VirtualMachine::new(config).map_err(|e| {
            anyhow::anyhow!(
                "creating VM for {instance}: {}",
                crate::error::friendly_error(&e)
            )
        })?;
        let pty = vm.serial_pty_paths().first().cloned();
        supervise(&VfrustVm(vm.handle()), &instance_dir, pty.as_deref()).await
    })
}

/// Persist the launch spec for the daemon to rebuild its VM config from.
pub fn write_launch_spec(instance_dir: &Path, spec: &LaunchSpec) -> Result<()> {
    let path = instance_dir.join(LAUNCH_SPEC_FILE);
    let json = serde_json::to_string_pretty(spec).context("serializing launch spec")?;
    fs::write(&path, json).with_context(|| format!("writing {}", path.display()))?;
    Ok(())
}

fn read_launch_spec(instance_dir: &Path) -> Result<LaunchSpec> {
    let path = instance_dir.join(LAUNCH_SPEC_FILE);
    let json = fs::read_to_string(&path).with_context(|| format!("reading {}", path.display()))?;
    serde_json::from_str(&json).with_context(|| format!("parsing {}", path.display()))
}

/// Where the daemon records its own pid on startup.
pub fn pid_file(instance_dir: &Path) -> PathBuf {
    instance_dir.join(PID_FILE)
}

/// The slice of `VmHandle` the supervisor needs. Seam for testing the loop
/// without Virtualization.framework.
pub(crate) trait VmControl {
    fn state(&self) -> VmState;
    fn state_stream(&self) -> watch::Receiver<VmState>;
    async fn start(&self) -> Result<()>;
    async fn request_stop(&self) -> Result<()>;
    async fn stop(&self) -> Result<()>;
}

struct VfrustVm(vfrust::VmHandle);

impl VmControl for VfrustVm {
    fn state(&self) -> VmState {
        self.0.state()
    }
    fn state_stream(&self) -> watch::Receiver<VmState> {
        self.0.state_stream()
    }
    async fn start(&self) -> Result<()> {
        self.0
            .start()
            .await
            .map_err(|e| anyhow::anyhow!("{}", crate::error::friendly_error(&e)))
    }
    async fn request_stop(&self) -> Result<()> {
        Ok(self.0.request_stop().await?)
    }
    async fn stop(&self) -> Result<()> {
        Ok(self.0.stop().await?)
    }
}

enum ShutdownPlan {
    /// `request_stop`, force after the grace period.
    Graceful(Duration),
    /// Force-stop now.
    Force,
    /// Guest already reached a terminal state; nothing to stop.
    AlreadyStopped,
}

/// Start the VM and run until something ends it: a control-socket stop, the
/// guest powering off, or SIGTERM.
///
/// `serial_pty_path` is the host pty slave for the guest serial port (from
/// `VirtualMachine::serial_pty_paths`), if any; the serial bridge tees it to
/// `console.log` and serves the interactive console socket.
pub(crate) async fn supervise<V: VmControl>(
    vm: &V,
    instance_dir: &Path,
    serial_pty_path: Option<&str>,
) -> Result<()> {
    vm.start().await?;

    if let Some(pty) = serial_pty_path {
        let console_log = instance_dir.join("console.log");
        let serial_sock = crate::serial_socket_path(instance_dir);
        if let Err(e) = crate::serial::spawn_bridge(pty, &console_log, &serial_sock) {
            // Console is non-essential; log and keep the VM running.
            eprintln!("serial bridge failed: {e:#}");
        }
    }

    fs::write(pid_file(instance_dir), std::process::id().to_string())
        .context("writing daemon pid file")?;
    let socket = control::socket_path(instance_dir);
    if socket.exists() {
        fs::remove_file(&socket).context("removing stale control socket")?;
    }
    let listener = UnixListener::bind(&socket)
        .with_context(|| format!("binding control socket: {}", socket.display()))?;

    let mut states = vm.state_stream();
    let mut sigterm = signal(SignalKind::terminate()).context("installing SIGTERM handler")?;

    let plan = loop {
        tokio::select! {
            conn = listener.accept() => {
                let (stream, _) = conn.context("accepting control connection")?;
                match serve_connection(vm, stream).await {
                    Ok(Some(plan)) => break plan,
                    Ok(None) => {}
                    // A misbehaving client must not take the VM down.
                    Err(e) => eprintln!("control connection error: {e:#}"),
                }
            }
            changed = states.changed() => {
                if changed.is_err() || terminal(*states.borrow_and_update()) {
                    break ShutdownPlan::AlreadyStopped;
                }
            }
            _ = sigterm.recv() => break ShutdownPlan::Graceful(SIGTERM_GRACE),
        }
    };

    match plan {
        ShutdownPlan::AlreadyStopped => {}
        ShutdownPlan::Graceful(grace) => shutdown_gracefully(vm, grace).await,
        ShutdownPlan::Force => force_stop(vm).await,
    }

    let _ = fs::remove_file(&socket);
    let _ = fs::remove_file(crate::serial_socket_path(instance_dir));
    let _ = fs::remove_file(pid_file(instance_dir));
    Ok(())
}

/// Handle one request on a fresh connection. Returns the shutdown plan the
/// request implies, if any.
async fn serve_connection<V: VmControl>(
    vm: &V,
    stream: UnixStream,
) -> Result<Option<ShutdownPlan>> {
    let (read, mut write) = stream.into_split();
    let mut line = String::new();
    BufReader::new(read)
        .read_line(&mut line)
        .await
        .context("reading control request")?;

    let (response, plan) = match control::decode::<Request>(&line) {
        Ok(Request::Status) => (
            Response::Status {
                status: instance_status(vm.state()),
            },
            None,
        ),
        Ok(Request::Stop { grace_seconds }) => (
            Response::Stopping,
            Some(ShutdownPlan::Graceful(Duration::from_secs(grace_seconds))),
        ),
        Ok(Request::KillNow) => (Response::Killed, Some(ShutdownPlan::Force)),
        Err(e) => (
            Response::Error {
                message: format!("{e:#}"),
            },
            None,
        ),
    };

    let reply = control::encode(&response)?;
    write
        .write_all(format!("{reply}\n").as_bytes())
        .await
        .context("writing control response")?;
    Ok(plan)
}

/// ACPI shutdown via `request_stop`, force-stop when the guest hasn't
/// reached a terminal state within `grace`.
async fn shutdown_gracefully<V: VmControl>(vm: &V, grace: Duration) {
    if terminal(vm.state()) {
        return;
    }
    if vm.request_stop().await.is_err() {
        force_stop(vm).await;
        return;
    }
    let mut states = vm.state_stream();
    let stopped = async {
        while !terminal(*states.borrow_and_update()) {
            if states.changed().await.is_err() {
                return;
            }
        }
    };
    if tokio::time::timeout(grace, stopped).await.is_err() {
        force_stop(vm).await;
    }
}

/// Best-effort force stop; an error here means the VM is already in a
/// terminal state, which is what we want.
async fn force_stop<V: VmControl>(vm: &V) {
    if !terminal(vm.state()) {
        let _ = vm.stop().await;
    }
}

fn terminal(state: VmState) -> bool {
    matches!(state, VmState::Stopped | VmState::Error)
}

fn instance_status(state: VmState) -> InstanceStatus {
    if terminal(state) {
        InstanceStatus::Stopped
    } else {
        InstanceStatus::Running
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::control::{Request, Response, send_request, socket_path};
    use std::sync::{Arc, Mutex};
    use tempfile::TempDir;

    #[derive(Clone)]
    struct MockVm {
        tx: watch::Sender<VmState>,
        calls: Arc<Mutex<Vec<&'static str>>>,
        /// Emulate a guest that honors ACPI power-button: `request_stop`
        /// transitions to Stopped.
        guest_honors_request_stop: bool,
    }

    impl MockVm {
        fn new(guest_honors_request_stop: bool) -> Self {
            MockVm {
                tx: watch::channel(VmState::Stopped).0,
                calls: Arc::new(Mutex::new(vec![])),
                guest_honors_request_stop,
            }
        }

        fn calls(&self) -> Vec<&'static str> {
            self.calls.lock().unwrap().clone()
        }
    }

    impl VmControl for MockVm {
        fn state(&self) -> VmState {
            *self.tx.borrow()
        }
        fn state_stream(&self) -> watch::Receiver<VmState> {
            self.tx.subscribe()
        }
        async fn start(&self) -> Result<()> {
            self.calls.lock().unwrap().push("start");
            self.tx.send_replace(VmState::Running);
            Ok(())
        }
        async fn request_stop(&self) -> Result<()> {
            self.calls.lock().unwrap().push("request_stop");
            if self.guest_honors_request_stop {
                self.tx.send_replace(VmState::Stopped);
            }
            Ok(())
        }
        async fn stop(&self) -> Result<()> {
            self.calls.lock().unwrap().push("stop");
            self.tx.send_replace(VmState::Stopped);
            Ok(())
        }
    }

    /// Block until the control socket appears, then run `requests`.
    fn client<T: Send + 'static>(
        dir: PathBuf,
        requests: impl FnOnce(&Path) -> T + Send + 'static,
    ) -> tokio::task::JoinHandle<T> {
        tokio::task::spawn_blocking(move || {
            let socket = socket_path(&dir);
            let deadline = std::time::Instant::now() + Duration::from_secs(5);
            while !socket.exists() {
                assert!(
                    std::time::Instant::now() < deadline,
                    "control socket never appeared"
                );
                std::thread::sleep(Duration::from_millis(10));
            }
            requests(&socket)
        })
    }

    #[tokio::test]
    async fn answers_status_writes_pid_file_and_force_stops_on_kill_now() {
        let dir = TempDir::new().unwrap();
        let vm = MockVm::new(true);
        let dir_path = dir.path().to_path_buf();

        let pid_path = pid_file(dir.path());
        let client = client(dir_path, move |socket| {
            let status = send_request(socket, &Request::Status).unwrap();
            let pid: u32 = std::fs::read_to_string(pid_path).unwrap().parse().unwrap();
            let killed = send_request(socket, &Request::KillNow).unwrap();
            (status, pid, killed)
        });

        supervise(&vm, dir.path(), None).await.unwrap();
        let (status, pid, killed) = client.await.unwrap();

        assert_eq!(
            status,
            Response::Status {
                status: InstanceStatus::Running
            }
        );
        assert_eq!(pid, std::process::id());
        assert_eq!(killed, Response::Killed);
        assert_eq!(vm.calls(), vec!["start", "stop"]);
        assert!(!socket_path(dir.path()).exists(), "socket cleaned up");
        assert!(!pid_file(dir.path()).exists(), "pid file cleaned up");
    }

    #[tokio::test]
    async fn graceful_stop_skips_force_when_guest_complies() {
        let dir = TempDir::new().unwrap();
        let vm = MockVm::new(true);

        let client = client(dir.path().to_path_buf(), |socket| {
            send_request(socket, &Request::Stop { grace_seconds: 5 }).unwrap()
        });

        supervise(&vm, dir.path(), None).await.unwrap();
        assert_eq!(client.await.unwrap(), Response::Stopping);
        assert_eq!(vm.calls(), vec!["start", "request_stop"]);
    }

    #[tokio::test]
    async fn force_stops_when_guest_ignores_request_stop() {
        let dir = TempDir::new().unwrap();
        let vm = MockVm::new(false);

        let client = client(dir.path().to_path_buf(), |socket| {
            send_request(socket, &Request::Stop { grace_seconds: 0 }).unwrap()
        });

        supervise(&vm, dir.path(), None).await.unwrap();
        assert_eq!(client.await.unwrap(), Response::Stopping);
        assert_eq!(vm.calls(), vec!["start", "request_stop", "stop"]);
    }

    #[tokio::test]
    async fn exits_without_stop_calls_when_guest_powers_off() {
        let dir = TempDir::new().unwrap();
        let vm = MockVm::new(true);
        let tx = vm.tx.clone();

        let poweroff = async {
            tokio::time::sleep(Duration::from_millis(50)).await;
            tx.send_replace(VmState::Stopped);
        };
        let (result, ()) = tokio::join!(supervise(&vm, dir.path(), None), poweroff);
        result.unwrap();

        assert_eq!(vm.calls(), vec!["start"]);
        assert!(!socket_path(dir.path()).exists(), "socket cleaned up");
    }

    #[tokio::test]
    async fn replies_error_to_garbage_and_keeps_serving() {
        let dir = TempDir::new().unwrap();
        let vm = MockVm::new(true);

        let client = client(dir.path().to_path_buf(), |socket| {
            use std::io::{BufRead, BufReader, Write};
            let mut stream = std::os::unix::net::UnixStream::connect(socket).unwrap();
            writeln!(stream, "not json").unwrap();
            let mut reply = String::new();
            BufReader::new(stream.try_clone().unwrap())
                .read_line(&mut reply)
                .unwrap();
            let garbage_reply: Response = crate::control::decode(&reply).unwrap();

            let killed = send_request(socket, &Request::KillNow).unwrap();
            (garbage_reply, killed)
        });

        supervise(&vm, dir.path(), None).await.unwrap();
        let (garbage_reply, killed) = client.await.unwrap();

        assert!(matches!(garbage_reply, Response::Error { .. }));
        assert_eq!(killed, Response::Killed);
    }

    #[test]
    fn launch_spec_file_roundtrip() {
        let dir = TempDir::new().unwrap();
        let spec = crate::tests::test_spec(dir.path().to_path_buf());
        write_launch_spec(dir.path(), &spec).unwrap();
        let loaded = read_launch_spec(dir.path()).unwrap();
        assert_eq!(loaded, spec);
    }

    #[test]
    fn read_launch_spec_missing_errors() {
        let dir = TempDir::new().unwrap();
        assert!(read_launch_spec(dir.path()).is_err());
    }
}
