pub mod args;
pub mod passt;
pub mod systemd;
pub mod virtiofsd;

use anyhow::{Context, Result, bail};
use std::fs;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::path::{Path, PathBuf};
use std::time::Duration;

use super::{
    Backend, BackendState, ChState, InstanceStatus, LaunchSpec, RunningInstance, SerialEndpoint,
};
use crate::instance_store;
use crate::{process, target};

pub struct CloudHypervisorBackend;

impl Backend for CloudHypervisorBackend {
    fn launch(&self, spec: &LaunchSpec) -> Result<RunningInstance> {
        let unit_id = process::generate_unit_id();
        let slice = systemd::slice_name(&spec.id, &unit_id)?;

        let result = launch_inner(spec, &unit_id, &slice);
        if result.is_err() {
            let _ = process::stop_unit(&slice);
        }
        result
    }

    fn stop(&self, instance: &RunningInstance, grace: Duration) -> Result<()> {
        let unit_id = ch_unit_id(instance);
        let vm_unit = systemd::vm_unit_name(&instance.id, unit_id)?;
        let slice = systemd::slice_name(&instance.id, unit_id)?;

        if grace.is_zero() {
            let _ = process::kill_unit(&vm_unit);
        } else {
            let _ = process::stop_unit(&vm_unit);
        }
        process::stop_unit(&slice)?;
        Ok(())
    }

    fn status(&self, instance: &RunningInstance) -> Result<InstanceStatus> {
        let unit_id = ch_unit_id(instance);
        let vm_unit = systemd::vm_unit_name(&instance.id, unit_id)?;
        if process::unit_is_active(&vm_unit)? {
            Ok(InstanceStatus::Running)
        } else {
            Ok(InstanceStatus::Stopped)
        }
    }
}

/// Extract the unit_id from a `RunningInstance` whose backend is CH.
/// Used by callers that already know they're working with a CH instance.
pub fn ch_unit_id(instance: &RunningInstance) -> &str {
    match &instance.backend {
        BackendState::CloudHypervisor(ch) => &ch.unit_id,
    }
}

fn launch_inner(spec: &LaunchSpec, unit_id: &str, slice: &str) -> Result<RunningInstance> {
    // Prepare writable disk overlay
    let disk_path = spec.instance_dir.join("disk.img");
    ensure_writable_disk(&spec.root_disk, &disk_path, &spec.disk_size)?;

    // Clean stale sockets
    let serial_socket = spec.instance_dir.join("serial.sock");
    if serial_socket.exists() {
        fs::remove_file(&serial_socket)?;
    }
    let serial_socket_str = serial_socket.to_string_lossy().to_string();

    let console_log = spec.instance_dir.join("console.log");
    let console_log_str = console_log.to_string_lossy().to_string();

    let api_socket = spec.instance_dir.join("api.sock");
    if api_socket.exists() {
        fs::remove_file(&api_socket)?;
    }
    let api_socket_str = api_socket.to_string_lossy().to_string();

    let vm_unit = systemd::vm_unit_name(&spec.id, unit_id)?;

    // Resolve required binaries (fail early if missing)
    let ch_remote_path = process::find_executable(args::CH_REMOTE_BINARY)
        .ok_or_else(|| anyhow::anyhow!("{} not found in PATH", args::CH_REMOTE_BINARY))?;
    let timeout_path = process::find_executable("timeout")
        .ok_or_else(|| anyhow::anyhow!("timeout not found in PATH"))?;
    let tail_path = process::find_executable("tail")
        .ok_or_else(|| anyhow::anyhow!("tail not found in PATH"))?;
    let sh_path =
        process::find_executable("sh").ok_or_else(|| anyhow::anyhow!("sh not found in PATH"))?;

    // Generate shutdown script with absolute paths
    let shutdown_script_path = spec.instance_dir.join("shutdown.sh");
    let shutdown_content = systemd::generate_shutdown_script(
        &api_socket_str,
        &ch_remote_path,
        &timeout_path,
        &tail_path,
        &sh_path,
    );
    fs::write(&shutdown_script_path, &shutdown_content).context("writing shutdown script")?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&shutdown_script_path, fs::Permissions::from_mode(0o755))
            .context("setting shutdown script permissions")?;
    }
    let shutdown_script_str = shutdown_script_path.to_string_lossy().to_string();

    // Write partial runtime so unit_id is recoverable if we crash mid-spawn
    instance_store::set_partial_runtime(&spec.id, unit_id)?;

    // Start passt for networking
    let passt_unit = systemd::passt_unit_name(&spec.id, unit_id)?;
    let passt_socket = spec.instance_dir.join("passt.sock");
    if passt_socket.exists() {
        fs::remove_file(&passt_socket)?;
    }
    passt::start_passt(
        &passt_unit,
        slice,
        Some(&vm_unit),
        &passt_socket.to_string_lossy(),
        spec.ssh_port,
        &spec.port_forwards,
    )?;

    let mut helper_units = vec![passt_unit.clone()];

    // Start virtiofsd for each shared dir
    let mut fs_args: Vec<String> = vec![];
    for (i, share) in spec.shares.iter().enumerate() {
        if !share.host_path.is_dir() {
            bail!(
                "share host_path is not a directory: {}",
                share.host_path.display()
            );
        }
        let vfsd_unit = systemd::virtiofsd_unit_name(&spec.id, unit_id, i)?;
        let vfsd_socket = spec.instance_dir.join(format!("virtiofsd-{i}.sock"));
        if vfsd_socket.exists() {
            fs::remove_file(&vfsd_socket)?;
        }
        virtiofsd::start_virtiofsd(
            &vfsd_unit,
            slice,
            Some(&vm_unit),
            &vfsd_socket.to_string_lossy(),
            &share.host_path.to_string_lossy(),
        )?;
        helper_units.push(vfsd_unit);
        fs_args.push(format!(
            "tag={},socket={}",
            share.tag,
            vfsd_socket.display()
        ));
    }

    // Build cloud-hypervisor command
    let disk_str = disk_path.to_string_lossy().to_string();
    let epidata_str = spec.epidata.to_string_lossy().to_string();
    let passt_socket_str = passt_socket.to_string_lossy().to_string();
    let kernel_str = spec.kernel.to_string_lossy().to_string();
    let initrd_str = spec
        .initrd
        .as_ref()
        .map(|p| p.to_string_lossy().to_string());

    let mac = generate_mac(&spec.id);

    let ch_args = args::build_args(&args::CloudHypervisorConfig {
        kernel: &kernel_str,
        initrd: initrd_str.as_deref(),
        disk_path: &disk_str,
        seed_iso: &epidata_str,
        cpus: spec.cpus,
        memory_mib: spec.memory_mib,
        cmdline: &spec.cmdline,
        serial_socket: &serial_socket_str,
        passt_socket: &passt_socket_str,
        fs_args: &fs_args,
        api_socket: Some(&api_socket_str),
        mac: &mac,
        console_log: &console_log_str,
    });
    let ch_refs: Vec<&str> = ch_args.iter().map(|s| s.as_str()).collect();

    // Generate systemd properties for VM lifecycle
    let properties = systemd::service_properties(Some(&shutdown_script_str), &helper_units);

    // Launch VM as systemd service
    let result = process::run_service(&vm_unit, slice, &properties, args::BINARY, &ch_refs)?;

    if !result.success() {
        bail!(
            "failed to launch VM (exit {}): {}",
            result.status,
            result.stderr
        );
    }

    // Brief pause to catch immediate exits
    std::thread::sleep(Duration::from_millis(150));
    if !process::unit_is_active(&vm_unit)? {
        let journal = process::journal_for_unit(&vm_unit).unwrap_or_default();
        if journal.is_empty() {
            bail!("VM exited immediately after launch (no journal output)");
        } else {
            bail!("VM exited immediately after launch:\n{journal}");
        }
    }

    Ok(RunningInstance {
        id: spec.id.clone(),
        ssh: SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), spec.ssh_port),
        serial: SerialEndpoint::UnixSocket {
            path: PathBuf::from(&serial_socket_str),
        },
        backend: BackendState::CloudHypervisor(ChState {
            unit_id: unit_id.to_string(),
        }),
        disk: disk_path.to_string_lossy().to_string(),
        ssh_key_path: spec
            .instance_dir
            .join("id_ed25519")
            .to_string_lossy()
            .to_string(),
        ports: spec.port_forwards.clone(),
    })
}

/// Generate a deterministic MAC address from an instance name.
///
/// Uses the locally administered prefix `02:` and hashes the name
/// to derive the remaining 5 octets.
fn generate_mac(instance_name: &str) -> String {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::hash::DefaultHasher::new();
    instance_name.hash(&mut hasher);
    let h = hasher.finish();
    let bytes = h.to_ne_bytes();
    format!(
        "02:{:02x}:{:02x}:{:02x}:{:02x}:{:02x}",
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4]
    )
}

fn ensure_writable_disk(source: &Path, dest: &Path, disk_size: &str) -> Result<()> {
    if dest.exists() {
        return Ok(());
    }

    process::require_binary("qemu-img", "qemu-utils")?;

    let source_str = source.to_string_lossy();
    if target::is_nix_store_path(&source_str) {
        // Create copy-on-write overlay
        let out = process::run(
            "qemu-img",
            &[
                "create",
                "-f",
                "qcow2",
                "-b",
                &source_str,
                "-F",
                "raw",
                &dest.to_string_lossy(),
            ],
        )?;
        if !out.success() {
            bail!("qemu-img create failed: {}", out.stderr);
        }
    } else {
        fs::copy(source, dest).context("copying disk image")?;
    }

    // Resize the virtual disk — the guest grows the partition at boot
    // via boot.growPartition.
    let dest_str = dest.to_string_lossy();
    let out = process::run("qemu-img", &["resize", &dest_str, disk_size])?;
    if !out.success() {
        bail!("qemu-img resize failed: {}", out.stderr);
    }

    Ok(())
}

pub(crate) fn wait_for_socket(path: &str, max_wait_ms: u64) -> Result<()> {
    let step = Duration::from_millis(50);
    let deadline = std::time::Instant::now() + Duration::from_millis(max_wait_ms);
    while std::time::Instant::now() < deadline {
        if Path::new(path).exists() {
            return Ok(());
        }
        std::thread::sleep(step);
    }
    bail!("socket did not appear: {path}");
}

/// Stop all units for an instance.
///
/// Thin wrapper around `Backend::stop` that reconstitutes a `RunningInstance`
/// from the persisted `Runtime`. With `force=false`, the VM unit's ExecStop
/// runs (graceful ACPI shutdown, capped by TimeoutStopSec). With `force=true`,
/// the VM main process is SIGKILL'd directly.
pub fn stop_instance(instance_name: &str, force: bool) -> Result<()> {
    let running = instance_store::find_runtime(instance_name)?
        .ok_or_else(|| anyhow::anyhow!("instance {instance_name} has no runtime"))?;

    let grace = if force {
        Duration::ZERO
    } else {
        Duration::from_secs(20)
    };

    CloudHypervisorBackend.stop(&running, grace)?;
    instance_store::clear_runtime(instance_name)?;
    Ok(())
}

/// Clean up a stale runtime: stop any leftover helper units and the slice,
/// remove stale sockets, and clear runtime state.
///
/// Use this when the VM unit is no longer active but runtime state still
/// references a unit_id — without this cleanup, helpers (passt/virtiofsd)
/// can survive a VM crash and block subsequent launches by holding sockets.
pub fn clear_stale_runtime(instance_name: &str) -> Result<()> {
    if let Some(state) = instance_store::load_state(instance_name)?
        && let Some(rt) = state.runtime.as_ref()
    {
        let unit_id = ch_unit_id(rt);
        let passt_unit = systemd::passt_unit_name(instance_name, unit_id)?;
        let _ = process::stop_unit(&passt_unit);
        for i in 0..state.mounts.len() {
            let vfsd_unit = systemd::virtiofsd_unit_name(instance_name, unit_id, i)?;
            let _ = process::stop_unit(&vfsd_unit);
        }
        let slice = systemd::slice_name(instance_name, unit_id)?;
        let _ = process::stop_unit(&slice);
    }

    let inst_dir = instance_store::instance_dir(instance_name);
    if inst_dir.exists() {
        remove_helper_sockets(&inst_dir)?;
    }

    instance_store::clear_runtime(instance_name)
}

fn remove_helper_sockets(inst_dir: &Path) -> Result<()> {
    for name in ["passt.sock", "serial.sock", "api.sock"] {
        let p = inst_dir.join(name);
        if p.exists() {
            fs::remove_file(&p)
                .with_context(|| format!("removing stale socket: {}", p.display()))?;
        }
    }
    let entries = fs::read_dir(inst_dir)
        .with_context(|| format!("reading instance dir: {}", inst_dir.display()))?;
    for entry in entries.flatten() {
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        if name.starts_with("virtiofsd-") && name.ends_with(".sock") {
            fs::remove_file(&path)
                .with_context(|| format!("removing stale socket: {}", path.display()))?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use tempfile::TempDir;

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn generate_mac_is_deterministic() {
        assert_eq!(generate_mac("myvm"), generate_mac("myvm"));
    }

    #[test]
    fn generate_mac_uses_locally_administered_prefix() {
        let mac = generate_mac("any-name");
        assert!(mac.starts_with("02:"), "got {mac}");
    }

    #[test]
    fn remove_helper_sockets_clears_known_helper_files() {
        let dir = TempDir::new().unwrap();
        let p = dir.path();
        for name in [
            "passt.sock",
            "serial.sock",
            "api.sock",
            "virtiofsd-0.sock",
            "virtiofsd-1.sock",
        ] {
            fs::write(p.join(name), "").unwrap();
        }
        fs::write(p.join("disk.img"), "keep").unwrap();
        fs::write(p.join("state.json"), "{}").unwrap();

        remove_helper_sockets(p).unwrap();

        for name in [
            "passt.sock",
            "serial.sock",
            "api.sock",
            "virtiofsd-0.sock",
            "virtiofsd-1.sock",
        ] {
            assert!(!p.join(name).exists(), "{name} should have been removed");
        }
        assert!(p.join("disk.img").exists(), "non-helper files preserved");
        assert!(p.join("state.json").exists(), "state.json preserved");
    }

    #[test]
    fn remove_helper_sockets_no_op_when_files_absent() {
        let dir = TempDir::new().unwrap();
        remove_helper_sockets(dir.path()).unwrap();
    }

    #[test]
    fn clear_stale_runtime_removes_sockets_and_clears_state() {
        let _lock = ENV_LOCK.lock().unwrap();
        let state_dir = TempDir::new().unwrap();
        unsafe { std::env::set_var("EPI_STATE_DIR", state_dir.path()) };
        unsafe { std::env::set_var("EPI_SYSTEMCTL_BIN", "/bin/true") };

        let name = "stalevm";
        let inst_dir = instance_store::ensure_instance_dir(name).unwrap();
        fs::write(inst_dir.join("passt.sock"), "").unwrap();
        fs::write(inst_dir.join("virtiofsd-0.sock"), "").unwrap();
        fs::write(inst_dir.join("serial.sock"), "").unwrap();

        let state = instance_store::InstanceState {
            target: ".#dev".into(),
            runtime: Some(RunningInstance {
                id: name.to_string(),
                ssh: SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 2222),
                serial: SerialEndpoint::UnixSocket {
                    path: PathBuf::new(),
                },
                backend: BackendState::CloudHypervisor(ChState {
                    unit_id: "deadbeef".into(),
                }),
                disk: String::new(),
                ssh_key_path: String::new(),
                ports: vec![],
            }),
            mounts: vec!["/tmp".into()],
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

        assert!(!inst_dir.join("passt.sock").exists());
        assert!(!inst_dir.join("virtiofsd-0.sock").exists());
        assert!(!inst_dir.join("serial.sock").exists());

        let after = instance_store::load_state(name).unwrap().unwrap();
        assert!(after.runtime.is_none());
        assert_eq!(after.target, ".#dev");

        unsafe { std::env::remove_var("EPI_STATE_DIR") };
        unsafe { std::env::remove_var("EPI_SYSTEMCTL_BIN") };
    }

    #[test]
    fn clear_stale_runtime_no_runtime_is_no_op() {
        let _lock = ENV_LOCK.lock().unwrap();
        let state_dir = TempDir::new().unwrap();
        unsafe { std::env::set_var("EPI_STATE_DIR", state_dir.path()) };
        unsafe { std::env::set_var("EPI_SYSTEMCTL_BIN", "/bin/true") };

        clear_stale_runtime("missing-instance").unwrap();

        unsafe { std::env::remove_var("EPI_STATE_DIR") };
        unsafe { std::env::remove_var("EPI_SYSTEMCTL_BIN") };
    }
}
