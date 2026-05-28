pub use epi_core::backend::*;

#[cfg(target_os = "linux")]
pub use epi_vmm_linux as ch;

use anyhow::{Context, Result};
use std::fs;

use crate::instance_store;

/// Return the backend impl responsible for an existing instance. Dispatch
/// is by the `BackendState` variant on the persisted `RunningInstance`.
pub fn backend_for(rt: &RunningInstance) -> Box<dyn Backend> {
    match &rt.backend {
        #[cfg(target_os = "linux")]
        BackendState::CloudHypervisor(_) => Box::new(ch::CloudHypervisorBackend),
    }
}

/// Whether the given instance is currently running, as observed by its backend.
/// Returns `Ok(false)` if no runtime is recorded for the instance.
pub fn instance_is_running(name: &str) -> Result<bool> {
    let Some(rt) = instance_store::find_runtime(name)? else {
        return Ok(false);
    };
    Ok(backend_for(&rt).status(&rt)? == InstanceStatus::Running)
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
            && backend_for(&rt).status(&rt)? == InstanceStatus::Running
        {
            return Ok(Some((name, rt)));
        }
    }
    Ok(None)
}
