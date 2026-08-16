//! macOS Virtualization.framework (VZ) backend.
//!
//! The VM itself is held by a long-lived helper process (`epi __vmm-daemon
//! <instance>`) because Virtualization.framework requires a resident
//! `VZVirtualMachine`. `VzBackend` spawns and signals that helper.
//!
//! `launch` prepares the disk overlay, persists the launch spec, and spawns
//! the daemon; `stop`/`status` go through the control socket (epi-22) with
//! a PID-signal fallback for a daemon that can't answer. IP discovery
//! (epi-26) lands separately.
#![cfg(target_os = "macos")]

pub mod control;
pub mod daemon;
pub mod error;
pub mod ip_discovery;
pub mod overlay;
pub mod serial;

pub use daemon::daemon_main;

use anyhow::{Context, Result, bail};
use std::net::{IpAddr, SocketAddr};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use nix::errno::Errno;
use nix::sys::signal::{Signal, kill};
use nix::unistd::Pid;

use epi_core::backend::{
    Backend, BackendState, InstanceStatus, LaunchSpec, RunningInstance, SerialEndpoint, VzState,
};
use epi_core::instance_store;

pub struct VzBackend;

/// The guest's sshd port — connections go straight to the VZ-NAT address.
const GUEST_SSH_PORT: u16 = 22;

/// Per-instance serial console socket served by the daemon's serial bridge.
/// Same unix-socket shape as the Linux backend, so `console::attach` is shared.
pub fn serial_socket_path(instance_dir: &Path) -> PathBuf {
    instance_dir.join("serial.sock")
}

/// How long launch waits for the guest to report its IP. Overridable for
/// tests via `EPI_VZ_IP_TIMEOUT_SECS`.
fn ip_timeout() -> Duration {
    std::env::var("EPI_VZ_IP_TIMEOUT_SECS")
        .ok()
        .and_then(|s| s.parse().ok())
        .map(Duration::from_secs)
        .unwrap_or(Duration::from_secs(120))
}

impl Backend for VzBackend {
    fn launch(&self, spec: &LaunchSpec) -> Result<RunningInstance> {
        let disk_path = spec.instance_dir.join("disk.img");
        overlay::ensure_writable_disk(&spec.root_disk, &disk_path, &spec.disk_size)?;
        daemon::write_launch_spec(&spec.instance_dir, spec)?;

        std::fs::create_dir_all(ip_discovery::guest_state_dir(&spec.instance_dir))
            .context("creating guest-state dir")?;
        ip_discovery::clear_stale_ip(&spec.instance_dir)?;

        let mut child = spawn_daemon(&spec.id, &spec.instance_dir)?;
        let pid = child.id();

        // Confirm the helper started the VM and is serving before we wait on
        // the (much longer) guest boot, then wait for the guest's VZ-NAT
        // address (ssh goes straight to it — no host port forward on macOS).
        // On any failure, reap the daemon so a failed launch leaks nothing;
        // if it already exited the readiness poll reaped it and kill/wait are
        // no-ops.
        let ip = wait_for_daemon_ready(&mut child, &spec.instance_dir)
            .and_then(|()| ip_discovery::wait_for_guest_ip(&spec.instance_dir, ip_timeout()));
        let ip = match ip {
            Ok(ip) => ip,
            Err(e) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(e);
            }
        };

        // Success: detach. Dropping `child` does not reap — the daemon keeps
        // running and launchd reaps it once epi exits.
        Ok(RunningInstance {
            id: spec.id.clone(),
            ssh: SocketAddr::new(IpAddr::V4(ip), GUEST_SSH_PORT),
            // The daemon's serial bridge serves this socket (pty ↔ console.log
            // + interactive), matching the Linux unix-socket console shape.
            serial: SerialEndpoint::UnixSocket {
                path: serial_socket_path(&spec.instance_dir),
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
        let socket = control::socket_path(&instance_store::instance_dir(&instance.id));
        let request = if grace.is_zero() {
            control::Request::KillNow
        } else {
            control::Request::Stop {
                grace_seconds: grace.as_secs(),
            }
        };
        match control::send_request(&socket, &request) {
            Ok(control::Response::Stopping) | Ok(control::Response::Killed) => {
                // The daemon coordinates guest shutdown and exits; allow it
                // the grace period plus margin before forcing.
                if !wait_for_exit(pid, grace + Duration::from_secs(10)) {
                    force_kill(pid)?;
                }
                Ok(())
            }
            Ok(control::Response::Error { message }) => bail!("vmm daemon: {message}"),
            Ok(other) => bail!("unexpected vmm daemon response: {other:?}"),
            // Socket gone or daemon wedged — signal the pid directly.
            Err(_) => signal_stop(pid, grace),
        }
    }

    fn status(&self, instance: &RunningInstance) -> Result<InstanceStatus> {
        let socket = control::socket_path(&instance_store::instance_dir(&instance.id));
        if let Ok(control::Response::Status { status }) =
            control::send_request(&socket, &control::Request::Status)
        {
            return Ok(status);
        }
        // Daemon gone or not serving yet — fall back to the pid probe.
        let pid = Pid::from_raw(vz_pid(instance)? as i32);
        if process_alive(pid) {
            Ok(InstanceStatus::Running)
        } else {
            Ok(InstanceStatus::Stopped)
        }
    }
}

/// PID-signal stop path: SIGTERM (the daemon's supervisor turns it into a
/// graceful guest shutdown), force after `grace`.
fn signal_stop(pid: Pid, grace: Duration) -> Result<()> {
    if grace.is_zero() {
        return force_kill(pid);
    }
    match kill(pid, Signal::SIGTERM) {
        Err(Errno::ESRCH) => return Ok(()),
        r => r.context("sending SIGTERM to vmm daemon")?,
    }
    if wait_for_exit(pid, grace) {
        return Ok(());
    }
    force_kill(pid)
}

/// Poll for daemon exit; true when the pid is gone before the deadline.
fn wait_for_exit(pid: Pid, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if !process_alive(pid) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    !process_alive(pid)
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
        .nested(true)
        .bootloader(vfrust::Bootloader::Linux(vfrust::LinuxBootloader {
            kernel_path: spec.kernel.clone(),
            initrd_path: spec.initrd.clone(),
            command_line: spec.cmdline.clone(),
        }))
        .device(vfrust::Device::VirtioBlk(vfrust::VirtioBlk {
            path: spec.instance_dir.join("disk.img"),
            read_only: false,
            // VZ's default Automatic caching corrupts ext4 under heavy I/O
            // (nix builds); Cached + Full is what UTM settled on.
            caching_mode: vfrust::DiskCachingMode::Cached,
            sync_mode: vfrust::DiskSyncMode::Full,
            ..vfrust::VirtioBlk::default()
        }))
        .device(vfrust::Device::VirtioBlk(vfrust::VirtioBlk {
            path: spec.epidata.clone(),
            read_only: true,
            ..vfrust::VirtioBlk::default()
        }))
        // epi-internal share the guest reports its IP through (epi-26).
        .device(vfrust::Device::VirtioFs(vfrust::VirtioFs {
            mount_tag: ip_discovery::GUEST_STATE_TAG.into(),
            shared_dir: Some(ip_discovery::guest_state_dir(&spec.instance_dir)),
            directories: vec![],
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
        .map_err(|e| {
            anyhow::anyhow!(
                "assembling vm config for {}: {}",
                spec.id,
                error::friendly_error(&e)
            )
        })?;
    Ok(config)
}

/// Extract the daemon pid from a `RunningInstance` whose backend is VZ.
pub fn vz_pid(instance: &RunningInstance) -> Result<u32> {
    match &instance.backend {
        BackendState::Vz(vz) => Ok(vz.pid),
        other => bail!("instance {} is not a vz instance: {other:?}", instance.id),
    }
}

/// Reap a stale instance whose daemon is gone: kill the daemon if somehow
/// still alive, remove the per-instance sockets/pid/ip files it leaves
/// behind, and clear the stored runtime. Idempotent — safe to call when
/// nothing is recorded.
pub fn clear_stale_runtime(instance: &str) -> Result<()> {
    if let Some(rt) = instance_store::find_runtime(instance)?
        && let Ok(pid) = vz_pid(&rt)
    {
        let _ = force_kill(Pid::from_raw(pid as i32));
    }

    let dir = instance_store::instance_dir(instance);
    let mut stale: Vec<PathBuf> = ["control.sock", "serial.sock", "daemon.pid"]
        .iter()
        .map(|f| dir.join(f))
        .collect();
    stale.push(ip_discovery::ip_file(&dir));
    for p in stale {
        if p.exists() {
            std::fs::remove_file(&p).with_context(|| format!("removing {}", p.display()))?;
        }
    }

    instance_store::clear_runtime(instance)
}

/// How long launch waits for the daemon to write its pid file (VM started,
/// control socket about to bind). Fast-fail on daemon death makes the crash
/// path return in milliseconds regardless.
const READY_TIMEOUT: Duration = Duration::from_secs(30);

/// Spawn the detached VM-holding helper with its output captured to
/// `daemon.log`. `setsid` puts it in its own session so it survives the
/// `epi` parent exiting — epi's "launch detaches, reconnect later" UX.
///
/// The returned `Child` is held only across launch's readiness/boot wait so
/// a failed launch can reap it. On success it is dropped without reaping;
/// the daemon keeps running and is reaped by launchd once `epi` exits.
fn spawn_daemon(instance: &str, instance_dir: &Path) -> Result<Child> {
    use std::os::unix::process::CommandExt;

    let exe = match std::env::var("EPI_VZ_DAEMON_BIN") {
        Ok(p) => PathBuf::from(p),
        Err(_) => std::env::current_exe().context("resolving epi binary path")?,
    };
    let log =
        std::fs::File::create(instance_dir.join("daemon.log")).context("creating daemon log")?;
    let mut cmd = Command::new(&exe);
    cmd.args(["__vmm-daemon", instance])
        .stdin(Stdio::null())
        .stdout(log.try_clone().context("cloning daemon log handle")?)
        .stderr(log);
    // SAFETY: setsid is async-signal-safe, the only requirement for a
    // post-fork pre_exec closure. It detaches the helper into a new session.
    unsafe {
        cmd.pre_exec(|| {
            nix::unistd::setsid().map_err(|e| std::io::Error::from_raw_os_error(e as i32))?;
            Ok(())
        });
    }
    cmd.spawn()
        .with_context(|| format!("spawning vmm daemon: {}", exe.display()))
}

/// Block until the detached daemon writes its pid file — meaning it created
/// the VM, started it, and is about to serve the control socket. Fails fast
/// if the daemon exits during startup (bad config, missing entitlement).
///
/// `try_wait` reaps the daemon if it has exited; a `kill(pid, 0)` probe
/// can't, since the daemon is our (zombie) child until reaped.
fn wait_for_daemon_ready(child: &mut Child, instance_dir: &Path) -> Result<()> {
    let pidfile = daemon::pid_file(instance_dir);
    let deadline = Instant::now() + READY_TIMEOUT;
    loop {
        if pidfile.exists() {
            return Ok(());
        }
        if let Some(status) = child.try_wait().context("polling vmm daemon")? {
            let log = std::fs::read_to_string(instance_dir.join("daemon.log")).unwrap_or_default();
            let log = log.trim();
            if log.is_empty() {
                bail!("vmm daemon exited during startup ({status})");
            }
            bail!("vmm daemon exited during startup ({status}):\n{log}");
        }
        if Instant::now() >= deadline {
            bail!(
                "vmm daemon did not become ready within {}s",
                READY_TIMEOUT.as_secs()
            );
        }
        std::thread::sleep(Duration::from_millis(50));
    }
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
pub(crate) mod tests {
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
        vz_runtime_named("testvm", pid)
    }

    fn vz_runtime_named(id: &str, pid: u32) -> RunningInstance {
        RunningInstance {
            id: id.into(),
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

    pub(crate) fn test_spec(instance_dir: PathBuf) -> LaunchSpec {
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
    fn vm_config_enables_nested_virtualization() {
        let spec = test_spec(PathBuf::from("/inst/testvm"));
        let config = vm_config(&spec).unwrap();
        assert!(
            config.nested(),
            "vz backend should enable nested virtualization"
        );
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
                // VZ's default Automatic caching corrupts ext4 under heavy
                // I/O; Cached + Full is the configuration UTM settled on.
                assert!(matches!(blk.caching_mode, vfrust::DiskCachingMode::Cached));
                assert!(matches!(blk.sync_mode, vfrust::DiskSyncMode::Full));
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
        // epi-internal guest-state share for IP reporting
        match &devices[2] {
            vfrust::Device::VirtioFs(fs) => {
                assert_eq!(fs.mount_tag, ip_discovery::GUEST_STATE_TAG);
                assert_eq!(
                    fs.shared_dir,
                    Some(PathBuf::from("/inst/testvm/guest-state"))
                );
            }
            other => panic!("expected epistate virtio-fs, got {other:?}"),
        }
        // NAT network, VZ-assigned mac
        match &devices[3] {
            vfrust::Device::VirtioNet(net) => {
                assert!(matches!(net.attachment, vfrust::NetAttachment::Nat));
                assert!(net.mac_address.is_none());
            }
            other => panic!("expected virtio-net, got {other:?}"),
        }
        // Pty serial console
        match &devices[4] {
            vfrust::Device::VirtioSerial(serial) => {
                assert!(matches!(serial.attachment, vfrust::SerialAttachment::Pty));
            }
            other => panic!("expected virtio-serial, got {other:?}"),
        }
        assert_eq!(devices.len(), 5, "no user shares -> exactly 5 devices");
    }

    #[test]
    fn vm_config_virtiofs_share_per_mount_keeps_tags() {
        let mut spec = test_spec(PathBuf::from("/inst/testvm"));
        spec.shares = vec![
            epi_core::backend::SharedDir {
                tag: "hostfs-0".into(),
                host_path: PathBuf::from("/Users/me/project"),
                guest_path: PathBuf::from("/Users/me/project"),
                read_only: false,
            },
            epi_core::backend::SharedDir {
                tag: "hostfs-1".into(),
                host_path: PathBuf::from("/Users/me/data"),
                guest_path: PathBuf::from("/Users/me/data"),
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
        assert_eq!(fs_devices.len(), 3, "epistate + two user shares");
        assert_eq!(fs_devices[0].mount_tag, ip_discovery::GUEST_STATE_TAG);
        assert_eq!(fs_devices[1].mount_tag, "hostfs-0");
        assert_eq!(
            fs_devices[1].shared_dir,
            Some(PathBuf::from("/Users/me/project"))
        );
        assert_eq!(fs_devices[2].mount_tag, "hostfs-1");
        assert_eq!(
            fs_devices[2].shared_dir,
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

    /// Mock daemon socket: serves one connection, records the request,
    /// replies with `response`.
    fn spawn_control_daemon(
        socket: PathBuf,
        response: control::Response,
    ) -> (
        std::sync::Arc<Mutex<Vec<control::Request>>>,
        std::thread::JoinHandle<()>,
    ) {
        use std::io::{BufRead, BufReader, Write};
        let received = std::sync::Arc::new(Mutex::new(vec![]));
        let recorder = received.clone();
        let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
        let handle = std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut writer = stream;
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            recorder
                .lock()
                .unwrap()
                .push(control::decode::<control::Request>(&line).unwrap());
            writeln!(writer, "{}", control::encode(&response).unwrap()).unwrap();
        });
        (received, handle)
    }

    #[test]
    fn spawn_daemon_detaches_into_new_session() {
        let _lock = ENV_LOCK.lock().unwrap();
        let dir = TempDir::new().unwrap();
        let pid_file = dir.path().join("fake.pid");
        let fake_daemon = dir.path().join("fake-daemon.sh");
        std::fs::write(
            &fake_daemon,
            format!(
                "#!/bin/sh\necho $$ > \"{}\"\nsleep 30\n",
                pid_file.display()
            ),
        )
        .unwrap();
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&fake_daemon, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        unsafe { std::env::set_var("EPI_VZ_DAEMON_BIN", &fake_daemon) };

        let mut child = spawn_daemon("detachtest", dir.path()).unwrap();
        unsafe { std::env::remove_var("EPI_VZ_DAEMON_BIN") };

        let pid = Pid::from_raw(child.id() as i32);
        // setsid makes the child a session and process-group leader: its pgid
        // equals its pid, and differs from this test process's group.
        let child_pgid = nix::unistd::getpgid(Some(pid)).unwrap();
        let own_pgid = nix::unistd::getpgid(None).unwrap();
        assert_eq!(child_pgid, pid, "daemon should lead its own group");
        assert_ne!(child_pgid, own_pgid, "daemon detached from launcher group");

        let _ = child.kill();
        let _ = child.wait();
    }

    #[test]
    fn launch_fails_fast_when_daemon_exits_during_startup() {
        let _lock = ENV_LOCK.lock().unwrap();
        let dir = TempDir::new().unwrap();
        // Daemon exits immediately without ever readying.
        let fake_daemon = dir.path().join("fake-daemon.sh");
        std::fs::write(&fake_daemon, "#!/bin/sh\necho boom >&2\nexit 7\n").unwrap();
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&fake_daemon, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        unsafe { std::env::set_var("EPI_VZ_DAEMON_BIN", &fake_daemon) };
        // Long IP timeout: the readiness gate must fail well before this.
        unsafe { std::env::set_var("EPI_VZ_IP_TIMEOUT_SECS", "120") };

        let mut spec = test_spec(dir.path().to_path_buf());
        let base_image = dir.path().join("base.raw");
        std::fs::write(&base_image, b"bootsector").unwrap();
        spec.root_disk = base_image;
        spec.disk_size = "1M".into();

        let start = std::time::Instant::now();
        let err = VzBackend.launch(&spec).unwrap_err();
        let elapsed = start.elapsed();

        unsafe { std::env::remove_var("EPI_VZ_DAEMON_BIN") };
        unsafe { std::env::remove_var("EPI_VZ_IP_TIMEOUT_SECS") };

        assert!(
            elapsed < Duration::from_secs(30),
            "should fail fast, took {elapsed:?}"
        );
        assert!(err.to_string().contains("daemon"), "{err}");
    }

    #[test]
    fn launch_kills_daemon_when_guest_never_reports_ip() {
        let _lock = ENV_LOCK.lock().unwrap();
        let dir = TempDir::new().unwrap();
        // Fake daemon readies (writes its pid file) but never reports an IP.
        let fake_daemon = dir.path().join("fake-daemon.sh");
        std::fs::write(
            &fake_daemon,
            format!(
                "#!/bin/sh\necho $$ > \"{}\"\nsleep 30\n",
                daemon::pid_file(dir.path()).display()
            ),
        )
        .unwrap();
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&fake_daemon, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        unsafe { std::env::set_var("EPI_VZ_DAEMON_BIN", &fake_daemon) };
        unsafe { std::env::set_var("EPI_VZ_IP_TIMEOUT_SECS", "1") };

        let mut spec = test_spec(dir.path().to_path_buf());
        let base_image = dir.path().join("base.raw");
        std::fs::write(&base_image, b"bootsector").unwrap();
        spec.root_disk = base_image;
        spec.disk_size = "1M".into();
        let err = VzBackend.launch(&spec).unwrap_err();

        unsafe { std::env::remove_var("EPI_VZ_DAEMON_BIN") };
        unsafe { std::env::remove_var("EPI_VZ_IP_TIMEOUT_SECS") };

        assert!(err.to_string().contains("never reported"), "{err}");
        // The failed launch must not leak the daemon — it kills and reaps it,
        // so the pid is gone.
        let pid: i32 = std::fs::read_to_string(daemon::pid_file(dir.path()))
            .expect("fake daemon wrote its pid")
            .trim()
            .parse()
            .unwrap();
        assert!(
            !process_alive(Pid::from_raw(pid)),
            "daemon should have been killed and reaped"
        );
    }

    #[test]
    fn clear_stale_runtime_removes_helpers_and_clears_state() {
        let _lock = ENV_LOCK.lock().unwrap();
        let state_dir = TempDir::new().unwrap();
        unsafe { std::env::set_var("EPI_STATE_DIR", state_dir.path()) };

        let name = "stalevm";
        let inst_dir = instance_store::ensure_instance_dir(name).unwrap();
        for f in ["control.sock", "serial.sock", "daemon.pid"] {
            std::fs::write(inst_dir.join(f), "").unwrap();
        }
        std::fs::create_dir_all(ip_discovery::guest_state_dir(&inst_dir)).unwrap();
        std::fs::write(ip_discovery::ip_file(&inst_dir), "192.168.64.5").unwrap();

        let state = instance_store::InstanceState {
            target: ".#dev".into(),
            // A dead pid (init is never our reapable daemon).
            runtime: Some(vz_runtime_named(name, 999_999)),
            mounts: vec![],
            project_dir: None,
            disk_size: String::new(),
            cpus: 1,
            memory_mib: 1024,
            port_specs: vec![],
            ssh_extra_config: vec![],
            descriptor: None,
        };
        instance_store::save_state(name, &state).unwrap();

        clear_stale_runtime(name).unwrap();

        for f in ["control.sock", "serial.sock", "daemon.pid"] {
            assert!(!inst_dir.join(f).exists(), "{f} should be removed");
        }
        assert!(!ip_discovery::ip_file(&inst_dir).exists());
        let after = instance_store::load_state(name).unwrap().unwrap();
        assert!(after.runtime.is_none(), "runtime should be cleared");
        assert_eq!(after.target, ".#dev", "non-runtime state preserved");

        unsafe { std::env::remove_var("EPI_STATE_DIR") };
    }

    #[test]
    fn clear_stale_runtime_no_runtime_is_ok() {
        let _lock = ENV_LOCK.lock().unwrap();
        let state_dir = TempDir::new().unwrap();
        unsafe { std::env::set_var("EPI_STATE_DIR", state_dir.path()) };
        clear_stale_runtime("missing-instance").unwrap();
        unsafe { std::env::remove_var("EPI_STATE_DIR") };
    }

    #[test]
    fn status_prefers_control_socket_over_pid() {
        let _lock = ENV_LOCK.lock().unwrap();
        let state_dir = TempDir::new().unwrap();
        unsafe { std::env::set_var("EPI_STATE_DIR", state_dir.path()) };

        let name = "socktest-status";
        let inst_dir = instance_store::ensure_instance_dir(name).unwrap();
        let (_, server) = spawn_control_daemon(
            control::socket_path(&inst_dir),
            control::Response::Status {
                status: InstanceStatus::Stopped,
            },
        );

        // Live pid, but the daemon says Stopped — socket wins.
        let mut child = spawn_sleeper();
        let rt = vz_runtime_named(name, child.id());
        let status = VzBackend.status(&rt).unwrap();
        child.kill().unwrap();
        child.wait().unwrap();
        server.join().unwrap();
        unsafe { std::env::remove_var("EPI_STATE_DIR") };

        assert_eq!(status, InstanceStatus::Stopped);
    }

    #[test]
    fn stop_sends_grace_over_control_socket() {
        let _lock = ENV_LOCK.lock().unwrap();
        let state_dir = TempDir::new().unwrap();
        unsafe { std::env::set_var("EPI_STATE_DIR", state_dir.path()) };

        let name = "socktest-stop";
        let inst_dir = instance_store::ensure_instance_dir(name).unwrap();
        let (received, server) =
            spawn_control_daemon(control::socket_path(&inst_dir), control::Response::Stopping);

        // Daemon pid already gone: stop should return as soon as the daemon
        // acknowledges.
        let mut child = spawn_sleeper();
        let pid = child.id();
        child.kill().unwrap();
        child.wait().unwrap();

        let rt = vz_runtime_named(name, pid);
        let result = VzBackend.stop(&rt, Duration::from_secs(20));
        server.join().unwrap();
        unsafe { std::env::remove_var("EPI_STATE_DIR") };

        result.unwrap();
        assert_eq!(
            received.lock().unwrap().clone(),
            vec![control::Request::Stop { grace_seconds: 20 }]
        );
    }

    #[test]
    fn force_stop_sends_kill_now_over_control_socket() {
        let _lock = ENV_LOCK.lock().unwrap();
        let state_dir = TempDir::new().unwrap();
        unsafe { std::env::set_var("EPI_STATE_DIR", state_dir.path()) };

        let name = "socktest-kill";
        let inst_dir = instance_store::ensure_instance_dir(name).unwrap();
        let (received, server) =
            spawn_control_daemon(control::socket_path(&inst_dir), control::Response::Killed);

        let mut child = spawn_sleeper();
        let pid = child.id();
        child.kill().unwrap();
        child.wait().unwrap();

        let rt = vz_runtime_named(name, pid);
        let result = VzBackend.stop(&rt, Duration::ZERO);
        server.join().unwrap();
        unsafe { std::env::remove_var("EPI_STATE_DIR") };

        result.unwrap();
        assert_eq!(
            received.lock().unwrap().clone(),
            vec![control::Request::KillNow]
        );
    }

    #[test]
    fn launch_spawns_daemon_and_returns_vz_state() {
        let _lock = ENV_LOCK.lock().unwrap();
        let dir = TempDir::new().unwrap();
        // Fake daemon readies (writes its pid file) then reports the guest
        // IP, like the real supervisor + guest unit would.
        let fake_daemon = dir.path().join("fake-daemon.sh");
        std::fs::write(
            &fake_daemon,
            format!(
                "#!/bin/sh\necho $$ > \"{}\"\nprintf '192.168.64.5\\n' > \"{}\"\nsleep 30\n",
                daemon::pid_file(dir.path()).display(),
                ip_discovery::ip_file(dir.path()).display()
            ),
        )
        .unwrap();
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

        assert_eq!(
            rt.ssh,
            "192.168.64.5:22".parse::<SocketAddr>().unwrap(),
            "ssh targets the guest-reported IP on the guest sshd port"
        );

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
        assert!(
            dir.path().join("launch-spec.json").exists(),
            "launch persists the spec for the daemon"
        );
        assert!(
            dir.path().join("daemon.log").exists(),
            "daemon output captured to log"
        );
        assert_eq!(rt.ports, vec![]);
        match &rt.serial {
            SerialEndpoint::UnixSocket { path } => {
                assert_eq!(path, &serial_socket_path(dir.path()));
            }
            other => panic!("expected unix-socket serial endpoint, got {other:?}"),
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
