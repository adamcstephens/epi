//! macOS Virtualization.framework (VZ) backend.
//!
//! The VM itself is held by a long-lived helper process (`epi __vmm-daemon
//! <instance>`) because Virtualization.framework requires a resident
//! `VZVirtualMachine`. `VzBackend` spawns and signals that helper.
//!
//! Current state: launch spawns the daemon (epi-21) and `vm_config`
//! assembles the device tree (epi-25); stop/status are PID-based. The
//! control-socket protocol (epi-22), supervisor loop (epi-27), and IP
//! discovery (epi-26) land separately.
#![cfg(target_os = "macos")]

pub mod overlay;

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
        let disk_path = spec.instance_dir.join("disk.img");
        overlay::ensure_writable_disk(&spec.root_disk, &disk_path, &spec.disk_size)?;

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
            disk: disk_path.to_string_lossy().to_string(),
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

/// Assemble the vfrust `VmConfig` for a launch.
///
/// Device order: root overlay disk, epidata seed ISO, one virtio-fs per
/// share (tags stay `hostfs-{N}` so the guest mount loop in
/// `nix/nixos/epi.nix` is unchanged), NAT network, pty serial console.
pub fn vm_config(spec: &LaunchSpec) -> Result<vfrust::VmConfig> {
    let mut builder = vfrust::VmConfig::builder()
        .cpus(spec.cpus)
        .memory_mib(u64::from(spec.memory_mib))
        .bootloader(vfrust::Bootloader::Linux(vfrust::LinuxBootloader {
            kernel_path: spec.kernel.clone(),
            initrd_path: spec.initrd.clone(),
            command_line: spec.cmdline.clone(),
        }))
        .device(vfrust::Device::VirtioBlk(vfrust::VirtioBlk {
            path: spec.instance_dir.join("disk.img"),
            read_only: false,
            ..vfrust::VirtioBlk::default()
        }))
        .device(vfrust::Device::VirtioBlk(vfrust::VirtioBlk {
            path: spec.epidata.clone(),
            read_only: true,
            ..vfrust::VirtioBlk::default()
        }));

    for share in &spec.shares {
        // VZ single-directory shares carry no read-only flag; epi only
        // creates writable shares today.
        builder = builder.device(vfrust::Device::VirtioFs(vfrust::VirtioFs {
            mount_tag: share.tag.clone(),
            shared_dir: Some(share.host_path.clone()),
            directories: vec![],
        }));
    }

    let config = builder
        .device(vfrust::Device::VirtioNet(vfrust::VirtioNet {
            attachment: vfrust::NetAttachment::Nat,
            mac_address: None,
        }))
        .device(vfrust::Device::VirtioSerial(vfrust::VirtioSerial {
            attachment: vfrust::SerialAttachment::Pty,
        }))
        .build()
        .map_err(|e| anyhow::anyhow!("assembling vm config for {}: {e}", spec.id))?;
    Ok(config)
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
    fn vm_config_resources_and_bootloader_from_spec() {
        let spec = test_spec(PathBuf::from("/inst/testvm"));
        let config = vm_config(&spec).unwrap();

        assert_eq!(config.cpus(), 2);
        assert_eq!(config.memory_mib(), 1024);
        match config.bootloader() {
            vfrust::Bootloader::Linux(linux) => {
                assert_eq!(linux.kernel_path, PathBuf::from("/nix/store/fake/kernel"));
                assert_eq!(linux.initrd_path, None);
                assert_eq!(linux.command_line, "console=hvc0");
            }
            other => panic!("expected linux bootloader, got {other:?}"),
        }
    }

    #[test]
    fn vm_config_initrd_passed_through() {
        let mut spec = test_spec(PathBuf::from("/inst/testvm"));
        spec.initrd = Some(PathBuf::from("/nix/store/fake/initrd"));
        let config = vm_config(&spec).unwrap();

        match config.bootloader() {
            vfrust::Bootloader::Linux(linux) => {
                assert_eq!(
                    linux.initrd_path,
                    Some(PathBuf::from("/nix/store/fake/initrd"))
                );
            }
            other => panic!("expected linux bootloader, got {other:?}"),
        }
    }

    #[test]
    fn vm_config_devices_disks_net_serial() {
        let spec = test_spec(PathBuf::from("/inst/testvm"));
        let config = vm_config(&spec).unwrap();
        let devices = config.devices();

        // Root overlay disk: writable, inside the instance dir
        match &devices[0] {
            vfrust::Device::VirtioBlk(blk) => {
                assert_eq!(blk.path, PathBuf::from("/inst/testvm/disk.img"));
                assert!(!blk.read_only);
            }
            other => panic!("expected root virtio-blk, got {other:?}"),
        }
        // epidata seed ISO: read-only
        match &devices[1] {
            vfrust::Device::VirtioBlk(blk) => {
                assert_eq!(blk.path, PathBuf::from("/inst/testvm/epidata.iso"));
                assert!(blk.read_only);
            }
            other => panic!("expected epidata virtio-blk, got {other:?}"),
        }
        // NAT network, VZ-assigned mac
        match &devices[2] {
            vfrust::Device::VirtioNet(net) => {
                assert!(matches!(net.attachment, vfrust::NetAttachment::Nat));
                assert!(net.mac_address.is_none());
            }
            other => panic!("expected virtio-net, got {other:?}"),
        }
        // Pty serial console
        match &devices[3] {
            vfrust::Device::VirtioSerial(serial) => {
                assert!(matches!(serial.attachment, vfrust::SerialAttachment::Pty));
            }
            other => panic!("expected virtio-serial, got {other:?}"),
        }
        assert_eq!(devices.len(), 4, "no shares -> exactly 4 devices");
    }

    #[test]
    fn vm_config_virtiofs_share_per_mount_keeps_tags() {
        let mut spec = test_spec(PathBuf::from("/inst/testvm"));
        spec.shares = vec![
            epi_core::backend::SharedDir {
                tag: "hostfs-0".into(),
                host_path: PathBuf::from("/Users/me/project"),
                read_only: false,
            },
            epi_core::backend::SharedDir {
                tag: "hostfs-1".into(),
                host_path: PathBuf::from("/Users/me/data"),
                read_only: false,
            },
        ];
        let config = vm_config(&spec).unwrap();

        let fs_devices: Vec<_> = config
            .devices()
            .iter()
            .filter_map(|d| match d {
                vfrust::Device::VirtioFs(fs) => Some(fs),
                _ => None,
            })
            .collect();
        assert_eq!(fs_devices.len(), 2);
        assert_eq!(fs_devices[0].mount_tag, "hostfs-0");
        assert_eq!(
            fs_devices[0].shared_dir,
            Some(PathBuf::from("/Users/me/project"))
        );
        assert_eq!(fs_devices[1].mount_tag, "hostfs-1");
        assert_eq!(
            fs_devices[1].shared_dir,
            Some(PathBuf::from("/Users/me/data"))
        );
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

        let mut spec = test_spec(dir.path().to_path_buf());
        let base_image = dir.path().join("base.raw");
        std::fs::write(&base_image, b"bootsector").unwrap();
        spec.root_disk = base_image;
        spec.disk_size = "1M".into();
        let rt = VzBackend.launch(&spec).unwrap();

        unsafe { std::env::remove_var("EPI_VZ_DAEMON_BIN") };

        let pid = vz_pid(&rt).unwrap();
        assert_eq!(
            VzBackend.status(&rt).unwrap(),
            epi_core::backend::InstanceStatus::Running
        );
        assert_eq!(rt.id, "testvm");
        let overlay = dir.path().join("disk.img");
        assert_eq!(rt.disk, overlay.to_string_lossy(), "disk points at overlay");
        let overlay_meta = std::fs::metadata(&overlay).expect("launch creates the overlay");
        assert_eq!(overlay_meta.len(), 1 << 20, "overlay grown to disk_size");
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
