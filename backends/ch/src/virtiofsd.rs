use anyhow::{Result, bail};

use epi_core::process;

use crate::wait_for_socket;

pub fn start_virtiofsd(
    unit_name: &str,
    slice: &str,
    vm_unit: Option<&str>,
    socket_path: &str,
    shared_dir: &str,
) -> Result<()> {
    process::require_binary("virtiofsd", "virtiofsd")?;
    let out = process::run_helper(
        unit_name,
        slice,
        vm_unit,
        "virtiofsd",
        &[
            "--socket-path",
            socket_path,
            "--shared-dir",
            shared_dir,
            "--announce-submounts",
            "--sandbox",
            "none",
        ],
    )?;
    if !out.success() {
        bail!("failed to start virtiofsd: {}", out.stderr);
    }
    wait_for_socket(socket_path, 2000)?;
    Ok(())
}
