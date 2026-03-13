pub const BINARY: &str = "cloud-hypervisor";
pub const CH_REMOTE_BINARY: &str = "ch-remote";

/// Build cloud-hypervisor CLI arguments from structured inputs.
pub fn build_args(
    kernel: &str,
    initrd: Option<&str>,
    disk_path: &str,
    seed_iso: &str,
    cpus: u32,
    memory_mib: u32,
    cmdline: &str,
    serial_socket: &str,
    passt_socket: &str,
    fs_args: &[String],
    api_socket: Option<&str>,
    mac: &str,
) -> Vec<String> {
    let mut args = vec![
        "--kernel".to_string(),
        kernel.to_string(),
        "--disk".to_string(),
        format!("path={disk_path},image_type=qcow2,backing_files=on"),
        format!("path={seed_iso},readonly=on"),
        "--cpus".to_string(),
        format!("boot={cpus}"),
        "--memory".to_string(),
        format!("size={memory_mib}M,shared=on"),
        "--serial".to_string(),
        format!("socket={serial_socket}"),
        "--console".to_string(),
        "off".to_string(),
        "--cmdline".to_string(),
        cmdline.to_string(),
        "--net".to_string(),
        format!("vhost_user=true,socket={passt_socket},vhost_mode=client,mac={mac}"),
    ];

    if let Some(initrd) = initrd {
        args.push("--initramfs".to_string());
        args.push(initrd.to_string());
    }

    if !fs_args.is_empty() {
        args.push("--fs".to_string());
        args.extend(fs_args.iter().cloned());
    }

    if let Some(api_socket) = api_socket {
        args.push("--api-socket".to_string());
        args.push(format!("path={api_socket}"));
    }

    args
}

/// Build systemd service properties for cloud-hypervisor VM lifecycle.
///
/// When an API socket is provided, configures a graceful shutdown sequence:
/// 1. ACPI power-button (guest-clean shutdown)
/// 2. Wait up to 15s for CH to exit
/// 3. Force shutdown-vmm as fallback
/// Plus After= ordering so helpers stay alive during VM shutdown,
/// and TimeoutStopSec=20 as a hard safety net.
///
/// Helper cleanup is handled by PartOf= on the helper units themselves.
pub fn service_properties(shutdown_script: Option<&str>, helper_units: &[String]) -> Vec<String> {
    let mut props = Vec::new();

    if let Some(script_path) = shutdown_script {
        props.push(format!("ExecStop={script_path}"));
        props.push("TimeoutStopSec=20".to_string());
    }

    for unit in helper_units {
        props.push(format!("After={unit}"));
    }

    props
}

use std::path::Path;

/// Resolve required binaries and generate shutdown script content with absolute paths.
///
/// The script performs:
/// 1. ch-remote power-button (ACPI shutdown)
/// 2. timeout 15s waiting for main process to exit
/// 3. ch-remote shutdown-vmm (force fallback)
pub fn generate_shutdown_script(
    api_socket: &str,
    ch_remote: &Path,
    timeout_bin: &Path,
    tail_bin: &Path,
) -> String {
    let ch_remote = ch_remote.display();
    let timeout_bin = timeout_bin.display();
    let tail_bin = tail_bin.display();
    format!(
        "#!/usr/bin/env sh\n\
         {ch_remote} --api-socket {api_socket} power-button\n\
         {timeout_bin} 15 {tail_bin} --pid=$MAINPID -f /dev/null\n\
         {ch_remote} --api-socket {api_socket} shutdown-vmm\n"
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn generate_shutdown_script_uses_absolute_paths() {
        let content = generate_shutdown_script(
            "/tmp/inst/api.sock",
            Path::new("/nix/store/abc/bin/ch-remote"),
            Path::new("/nix/store/def/bin/timeout"),
            Path::new("/nix/store/ghi/bin/tail"),
        );
        assert!(content.starts_with("#!/usr/bin/env sh\n"));
        assert!(content.contains(
            "/nix/store/abc/bin/ch-remote --api-socket /tmp/inst/api.sock power-button\n"
        ));
        assert!(content.contains(
            "/nix/store/def/bin/timeout 15 /nix/store/ghi/bin/tail --pid=$MAINPID -f /dev/null\n"
        ));
        assert!(content.contains(
            "/nix/store/abc/bin/ch-remote --api-socket /tmp/inst/api.sock shutdown-vmm\n"
        ));
    }

    #[test]
    fn service_properties_with_shutdown_script() {
        let helpers = vec!["helper.service".to_string()];
        let props = service_properties(Some("/tmp/inst/shutdown.sh"), &helpers);
        assert_eq!(props[0], "ExecStop=/tmp/inst/shutdown.sh");
        assert_eq!(props[1], "TimeoutStopSec=20");
        assert_eq!(props[2], "After=helper.service");
    }

    #[test]
    fn service_properties_without_shutdown_script() {
        let helpers = vec!["helper.service".to_string()];
        let props = service_properties(None, &helpers);
        assert_eq!(props.len(), 1);
        assert_eq!(props[0], "After=helper.service");
    }
}
