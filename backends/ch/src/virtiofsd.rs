use anyhow::{Result, bail};

use epi_core::process;

use crate::wait_for_socket;

fn virtiofsd_args<'a>(socket_path: &'a str, shared_dir: &'a str, read_only: bool) -> Vec<&'a str> {
    let mut args = vec![
        "--socket-path",
        socket_path,
        "--shared-dir",
        shared_dir,
        "--announce-submounts",
        "--sandbox",
        "none",
    ];
    if read_only {
        args.push("--readonly");
    }
    args
}

pub fn start_virtiofsd(
    unit_name: &str,
    slice: &str,
    vm_unit: Option<&str>,
    socket_path: &str,
    shared_dir: &str,
    read_only: bool,
) -> Result<()> {
    process::require_binary("virtiofsd", "virtiofsd")?;
    let args = virtiofsd_args(socket_path, shared_dir, read_only);
    let out = process::run_helper(unit_name, slice, vm_unit, "virtiofsd", &args)?;
    if !out.success() {
        bail!("failed to start virtiofsd: {}", out.stderr);
    }
    wait_for_socket(socket_path, 2000)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn read_only_exports_pass_readonly_argument() {
        assert_eq!(
            virtiofsd_args("/tmp/virtiofs.sock", "/host/path", true),
            vec![
                "--socket-path",
                "/tmp/virtiofs.sock",
                "--shared-dir",
                "/host/path",
                "--announce-submounts",
                "--sandbox",
                "none",
                "--readonly",
            ]
        );
    }

    #[test]
    fn writable_exports_omit_readonly_argument() {
        assert!(!virtiofsd_args("/tmp/virtiofs.sock", "/host/path", false).contains(&"--readonly"));
    }
}
