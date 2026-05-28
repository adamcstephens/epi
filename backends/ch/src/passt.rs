use anyhow::{Result, bail};

use epi_core::backend::PortMapping;
use epi_core::process;

use crate::wait_for_socket;

pub fn start_passt(
    unit_name: &str,
    slice: &str,
    vm_unit: Option<&str>,
    socket_path: &str,
    ssh_port: u16,
    port_mappings: &[PortMapping],
) -> Result<()> {
    process::require_binary("passt", "passt")?;

    // Build TCP forward rules: SSH + user port mappings
    let mut tcp_fwds: Vec<String> = vec![format!("{ssh_port}:22")];
    for pm in port_mappings {
        tcp_fwds.push(format!("{}:{}", pm.host, pm.guest));
    }

    let mut args: Vec<&str> = vec!["--foreground", "--vhost-user", "--socket-path", socket_path];
    for fwd in &tcp_fwds {
        args.push("--tcp-ports");
        args.push(fwd);
    }

    let out = process::run_helper(unit_name, slice, vm_unit, "passt", &args)?;
    if !out.success() {
        bail!("failed to start passt: {}", out.stderr);
    }
    wait_for_socket(socket_path, 2000)?;
    Ok(())
}
