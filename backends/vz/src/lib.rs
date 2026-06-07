//! macOS Virtualization.framework (VZ) backend.
//!
//! The VM itself is held by a long-lived helper process (`epi __vmm-daemon
//! <instance>`) because Virtualization.framework requires a resident
//! `VZVirtualMachine`. `VzBackend` spawns and signals that helper.
//!
//! Current state (epi-21): launch spawns the daemon, stop/status are
//! PID-based. The control-socket protocol (epi-22), VmConfig assembly
//! (epi-25), and IP discovery (epi-26) land separately.
#![cfg(target_os = "macos")]

use anyhow::{Context, Result, bail};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::path::PathBuf;
use std::process::Command;
use std::time::{Duration, Instant};

use nix::errno::Errno;
use nix::sys::signal::{Signal, kill};
use nix::unistd::Pid;

use epi_core::backend::{
    Backend, BackendState, InstanceStatus, LaunchSpec, RunningInstance, SerialEndpoint, VzState,
};

pub struct VzBackend;

impl Backend for VzBackend {
    fn launch(&self, spec: &LaunchSpec) -> Result<RunningInstance> {
        let pid = spawn_daemon(&spec.id)?;
        Ok(RunningInstance {
            id: spec.id.clone(),
            // Placeholder: vmnet gives the guest its own address, discovered
            // post-boot (epi-26). Until then point at localhost.
            ssh: SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), spec.ssh_port),
            // The daemon symlinks the allocated pty slave here (epi-31/33).
            serial: SerialEndpoint::Pty {
                path: spec.instance_dir.join("console.pty"),
            },
            backend: BackendState::Vz(VzState { pid }),
            disk: spec
                .instance_dir
                .join("disk.img")
                .to_string_lossy()
                .to_string(),
            ssh_key_path: spec
                .instance_dir
                .join("id_ed25519")
                .to_string_lossy()
                .to_string(),
            ports: spec.port_forwards.clone(),
        })
    }

    fn stop(&self, instance: &RunningInstance, grace: Duration) -> Result<()> {
        let pid = Pid::from_raw(vz_pid(instance)? as i32);
        if grace.is_zero() {
            return force_kill(pid);
        }
        // PID-signal stop until the control socket lands (epi-22): the daemon
        // turns SIGTERM into a graceful guest shutdown before exiting.
        match kill(pid, Signal::SIGTERM) {
            Err(Errno::ESRCH) => return Ok(()),
            r => r.context("sending SIGTERM to vmm daemon")?,
        }
        let deadline = Instant::now() + grace;
        while Instant::now() < deadline {
            if !process_alive(pid) {
                return Ok(());
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        force_kill(pid)
    }

    fn status(&self, instance: &RunningInstance) -> Result<InstanceStatus> {
        let pid = Pid::from_raw(vz_pid(instance)? as i32);
        if process_alive(pid) {
            Ok(InstanceStatus::Running)
        } else {
            Ok(InstanceStatus::Stopped)
        }
    }
}

/// Extract the daemon pid from a `RunningInstance` whose backend is VZ.
pub fn vz_pid(instance: &RunningInstance) -> Result<u32> {
    match &instance.backend {
        BackendState::Vz(vz) => Ok(vz.pid),
        other => bail!("instance {} is not a vz instance: {other:?}", instance.id),
    }
}

/// Entrypoint for the hidden `epi __vmm-daemon <instance>` subcommand.
///
/// Holds the tokio runtime that will own the `VZVirtualMachine` (epi-25)
/// and serve the per-instance control socket (epi-22/27). Until those land
/// it parks until signalled; SIGTERM/SIGKILL from `VzBackend::stop`
/// terminates it.
pub fn daemon_main(instance: &str) -> Result<()> {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .with_context(|| format!("building vmm daemon runtime for {instance}"))?;
    runtime.block_on(std::future::pending::<()>());
    Ok(())
}

/// Spawn the detached VM-holding helper. Plain spawn for now; setsid /
/// posix_spawn detach hardening lands in epi-28.
fn spawn_daemon(instance: &str) -> Result<u32> {
    let exe = match std::env::var("EPI_VZ_DAEMON_BIN") {
        Ok(p) => PathBuf::from(p),
        Err(_) => std::env::current_exe().context("resolving epi binary path")?,
    };
    let child = Command::new(&exe)
        .args(["__vmm-daemon", instance])
        .spawn()
        .with_context(|| format!("spawning vmm daemon: {}", exe.display()))?;
    Ok(child.id())
}

/// `kill(pid, 0)` liveness probe. EPERM means the pid exists but is not
/// ours, so it counts as alive.
fn process_alive(pid: Pid) -> bool {
    !matches!(kill(pid, None), Err(Errno::ESRCH))
}

fn force_kill(pid: Pid) -> Result<()> {
    match kill(pid, Signal::SIGKILL) {
        Err(Errno::ESRCH) => Ok(()),
        r => Ok(r.context("sending SIGKILL to vmm daemon")?),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use epi_core::backend::{
        Backend, BackendState, ChState, LaunchSpec, RunningInstance, SerialEndpoint, VzState,
    };
    use std::net::{IpAddr, Ipv4Addr, SocketAddr};
    use std::path::PathBuf;
    use std::process::Command;
    use std::sync::Mutex;
    use std::time::Duration;
    use tempfile::TempDir;

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    fn vz_runtime(pid: u32) -> RunningInstance {
        RunningInstance {
            id: "testvm".into(),
            ssh: SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 2222),
            serial: SerialEndpoint::Pty {
                path: PathBuf::from("/tmp/console.pty"),
            },
            backend: BackendState::Vz(VzState { pid }),
            disk: "/inst/disk.img".into(),
            ssh_key_path: "/inst/id_ed25519".into(),
            ports: vec![],
        }
    }

    fn spawn_sleeper() -> std::process::Child {
        Command::new("/bin/sleep")
            .arg("30")
            .spawn()
            .expect("spawning sleeper")
    }

    fn test_spec(instance_dir: PathBuf) -> LaunchSpec {
        LaunchSpec {
            id: "testvm".into(),
            kernel: PathBuf::from("/nix/store/fake/kernel"),
            initrd: None,
            cmdline: "console=hvc0".into(),
            root_disk: PathBuf::from("/nix/store/fake/disk.img"),
            epidata: instance_dir.join("epidata.iso"),
            shares: vec![],
            cpus: 2,
            memory_mib: 1024,
            ssh_pubkey: "ssh-ed25519 AAAA test".into(),
            ssh_port: 2222,
            port_forwards: vec![],
            disk_size: "40G".into(),
            instance_dir,
        }
    }

    #[test]
    fn vz_pid_extracts_pid() {
        let rt = vz_runtime(4242);
        assert_eq!(vz_pid(&rt).unwrap(), 4242);
    }

    #[test]
    fn vz_pid_rejects_other_backend() {
        let mut rt = vz_runtime(1);
        rt.backend = BackendState::CloudHypervisor(ChState {
            unit_id: "u1".into(),
        });
        assert!(vz_pid(&rt).is_err());
    }

    #[test]
    fn status_running_for_live_pid() {
        let mut child = spawn_sleeper();
        let rt = vz_runtime(child.id());
        let status = VzBackend.status(&rt).unwrap();
        child.kill().unwrap();
        child.wait().unwrap();
        assert_eq!(status, epi_core::backend::InstanceStatus::Running);
    }

    #[test]
    fn status_stopped_for_dead_pid() {
        let mut child = spawn_sleeper();
        let pid = child.id();
        child.kill().unwrap();
        child.wait().unwrap();
        let rt = vz_runtime(pid);
        let status = VzBackend.status(&rt).unwrap();
        assert_eq!(status, epi_core::backend::InstanceStatus::Stopped);
    }

    #[test]
    fn stop_terminates_daemon_within_grace() {
        let mut child = spawn_sleeper();
        let rt = vz_runtime(child.id());
        // We are the sleeper's parent, so it stays a zombie (= alive to
        // kill(2)) until reaped. Reap concurrently so stop's liveness poll
        // sees it exit, as it would in production where epi stop is never
        // the daemon's parent.
        let reaper = std::thread::spawn(move || child.wait().unwrap());
        VzBackend.stop(&rt, Duration::from_secs(5)).unwrap();
        let status = reaper.join().unwrap();
        assert!(!status.success(), "sleeper should have been signalled");
        assert_eq!(
            VzBackend.status(&rt).unwrap(),
            epi_core::backend::InstanceStatus::Stopped
        );
    }

    #[test]
    fn stop_on_dead_pid_is_ok() {
        let mut child = spawn_sleeper();
        let pid = child.id();
        child.kill().unwrap();
        child.wait().unwrap();
        let rt = vz_runtime(pid);
        VzBackend.stop(&rt, Duration::from_secs(1)).unwrap();
    }

    #[test]
    fn launch_spawns_daemon_and_returns_vz_state() {
        let _lock = ENV_LOCK.lock().unwrap();
        let dir = TempDir::new().unwrap();
        let fake_daemon = dir.path().join("fake-daemon.sh");
        std::fs::write(&fake_daemon, "#!/bin/sh\nsleep 30\n").unwrap();
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&fake_daemon, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        unsafe { std::env::set_var("EPI_VZ_DAEMON_BIN", &fake_daemon) };

        let spec = test_spec(dir.path().to_path_buf());
        let rt = VzBackend.launch(&spec).unwrap();

        unsafe { std::env::remove_var("EPI_VZ_DAEMON_BIN") };

        let pid = vz_pid(&rt).unwrap();
        assert_eq!(
            VzBackend.status(&rt).unwrap(),
            epi_core::backend::InstanceStatus::Running
        );
        assert_eq!(rt.id, "testvm");
        assert_eq!(rt.ports, vec![]);
        match &rt.serial {
            SerialEndpoint::Pty { path } => {
                assert!(path.starts_with(dir.path()), "pty path in instance dir");
            }
            other => panic!("expected pty serial endpoint, got {other:?}"),
        }

        VzBackend.stop(&rt, Duration::ZERO).unwrap();
        // The daemon is our child (launch spawned it in-process), so reap
        // the zombie before checking liveness.
        nix::sys::wait::waitpid(nix::unistd::Pid::from_raw(pid as i32), None).unwrap();
        assert_eq!(
            VzBackend.status(&rt).unwrap(),
            epi_core::backend::InstanceStatus::Stopped
        );
    }
}
