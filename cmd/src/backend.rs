pub use epi_core::backend::*;

#[cfg(target_os = "linux")]
pub use epi_vmm_linux as ch;
#[cfg(target_os = "macos")]
pub use epi_vmm_macos as vz;

use anyhow::{Context, Result, bail};
use std::fs;
use std::time::Duration;

use crate::instance_store;

/// The backend used for new launches on this platform.
pub fn platform_backend() -> Box<dyn Backend> {
    #[cfg(target_os = "linux")]
    {
        Box::new(ch::CloudHypervisorBackend)
    }
    #[cfg(target_os = "macos")]
    {
        Box::new(vz::VzBackend)
    }
}

/// Return the backend impl responsible for an existing instance. Dispatch
/// is by the `BackendState` variant on the persisted `RunningInstance`.
/// Errors when the state was created by a backend from another platform.
pub fn backend_for(rt: &RunningInstance) -> Result<Box<dyn Backend>> {
    match &rt.backend {
        #[cfg(target_os = "linux")]
        BackendState::CloudHypervisor(_) => Ok(Box::new(ch::CloudHypervisorBackend)),
        #[cfg(target_os = "macos")]
        BackendState::Vz(_) => Ok(Box::new(vz::VzBackend)),
        #[allow(unreachable_patterns)]
        other => bail!(
            "instance {} was created by a backend unavailable on this platform: {other:?}",
            rt.id
        ),
    }
}

/// Stop an instance via its backend and clear the stored runtime.
///
/// With `force=false` the backend performs a graceful shutdown capped by a
/// grace period; with `force=true` it terminates the VM immediately.
pub fn stop_instance(instance_name: &str, force: bool) -> Result<()> {
    let running = instance_store::find_runtime(instance_name)?
        .ok_or_else(|| anyhow::anyhow!("instance {instance_name} has no runtime"))?;

    let grace = if force {
        Duration::ZERO
    } else {
        Duration::from_secs(20)
    };

    backend_for(&running)?.stop(&running, grace)?;
    instance_store::clear_runtime(instance_name)?;
    Ok(())
}

/// Clean up a stale runtime (recorded state whose VM is no longer running):
/// reap leftover helpers and clear the stored runtime.
pub fn clear_stale_runtime(instance: &str) -> Result<()> {
    #[cfg(target_os = "linux")]
    {
        ch::clear_stale_runtime(instance)
    }
    #[cfg(target_os = "macos")]
    {
        vz::clear_stale_runtime(instance)
    }
}

/// Whether the instance is running, reaping its stale runtime first if the
/// backend reports it stopped (dead daemon / torn-down units). Use in read
/// paths (`list`, `info`) so a crashed helper's leftover state is cleaned up
/// on inspection. Single status check, unlike `instance_is_running` +
/// separate reap.
pub fn is_running_reaping(name: &str) -> Result<bool> {
    let Some(rt) = instance_store::find_runtime(name)? else {
        return Ok(false);
    };
    if backend_for(&rt)?.status(&rt)? == InstanceStatus::Running {
        Ok(true)
    } else {
        clear_stale_runtime(name)?;
        Ok(false)
    }
}

/// Whether the given instance is currently running, as observed by its backend.
/// Returns `Ok(false)` if no runtime is recorded for the instance.
pub fn instance_is_running(name: &str) -> Result<bool> {
    let Some(rt) = instance_store::find_runtime(name)? else {
        return Ok(false);
    };
    Ok(backend_for(&rt)?.status(&rt)? == InstanceStatus::Running)
}

/// Scan all known instances for a running owner of `disk`. Returns the
/// (name, runtime) of the first match. Used to prevent two instances from
/// sharing the same overlay path concurrently.
pub fn find_running_owner_by_disk(disk: &str) -> Result<Option<(String, RunningInstance)>> {
    let dir = instance_store::state_dir();
    if !dir.exists() {
        return Ok(None);
    }
    for entry in fs::read_dir(&dir).with_context(|| format!("reading {}", dir.display()))? {
        let entry = entry?;
        if !entry.file_type()?.is_dir() {
            continue;
        }
        let name = entry.file_name().to_string_lossy().to_string();
        if let Some(state) = instance_store::load_state(&name)?
            && let Some(rt) = state.runtime
            && rt.disk == disk
            && backend_for(&rt)?.status(&rt)? == InstanceStatus::Running
        {
            return Ok(Some((name, rt)));
        }
    }
    Ok(None)
}
