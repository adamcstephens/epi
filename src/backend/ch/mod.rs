pub mod args;
pub mod passt;
pub mod systemd;
pub mod virtiofsd;

use anyhow::{Context, Result, bail};
use std::fs;
use std::path::Path;
use std::time::Duration;

use crate::instance_store::{self, Runtime};
use crate::process;

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
/// With `force=false`, the VM unit's ExecStop runs (graceful ACPI shutdown,
/// capped by TimeoutStopSec). With `force=true`, the VM main process is sent
/// SIGKILL directly — no ACPI, no waiting — and the slice is then stopped to
/// clean up helpers.
pub fn stop_instance(instance_name: &str, force: bool) -> Result<()> {
    let runtime: Runtime = instance_store::find_runtime(instance_name)?
        .ok_or_else(|| anyhow::anyhow!("instance {instance_name} has no runtime"))?;

    let vm_unit = instance_store::vm_unit_name(instance_name, &runtime.unit_id)?;
    let slice = instance_store::slice_name(instance_name, &runtime.unit_id)?;

    if force {
        let _ = process::kill_unit(&vm_unit);
    } else {
        let _ = process::stop_unit(&vm_unit);
    }
    process::stop_unit(&slice)?;

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
        let passt_unit = instance_store::passt_unit_name(instance_name, &rt.unit_id)?;
        let _ = process::stop_unit(&passt_unit);
        for i in 0..state.mounts.len() {
            let vfsd_unit = instance_store::virtiofsd_unit_name(instance_name, &rt.unit_id, i)?;
            let _ = process::stop_unit(&vfsd_unit);
        }
        let slice = instance_store::slice_name(instance_name, &rt.unit_id)?;
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
            runtime: Some(Runtime {
                unit_id: "deadbeef".into(),
                serial_socket: String::new(),
                disk: String::new(),
                ssh_port: Some(2222),
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
