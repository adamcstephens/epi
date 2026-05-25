use std::path::Path;

/// Build systemd service properties for cloud-hypervisor VM lifecycle.
///
/// When an API socket is provided, configures a graceful shutdown sequence:
/// 1. ACPI power-button (guest-clean shutdown)
/// 2. Wait up to 15s for CH to exit
/// 3. Force shutdown-vmm as fallback
///    Plus After= ordering so helpers stay alive during VM shutdown,
///    and TimeoutStopSec=20 as a hard safety net.
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

/// Resolve required binaries and generate shutdown script content with absolute paths.
///
/// The script performs:
/// 1. ch-remote power-button (ACPI shutdown)
/// 2. timeout 10s waiting for main process to exit
/// 3. ch-remote shutdown-vmm (force fallback)
pub fn generate_shutdown_script(
    api_socket: &str,
    ch_remote: &Path,
    timeout_bin: &Path,
    tail_bin: &Path,
    sh_bin: &Path,
) -> String {
    let sh_bin = sh_bin.display();
    let ch_remote = ch_remote.display();
    let timeout_bin = timeout_bin.display();
    let tail_bin = tail_bin.display();
    format!(
        "#!{sh_bin}\n\
         {ch_remote} --api-socket {api_socket} power-button\n\
         {timeout_bin} 10 {tail_bin} --pid=$MAINPID -f /dev/null\n\
         {ch_remote} --api-socket {api_socket} shutdown-vmm || true\n"
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
            Path::new("/nix/store/xyz/bin/sh"),
        );
        assert!(content.starts_with("#!/nix/store/xyz/bin/sh\n"));
        assert!(content.contains(
            "/nix/store/abc/bin/ch-remote --api-socket /tmp/inst/api.sock power-button\n"
        ));
        assert!(content.contains(
            "/nix/store/def/bin/timeout 10 /nix/store/ghi/bin/tail --pid=$MAINPID -f /dev/null\n"
        ));
        assert!(content.contains(
            "/nix/store/abc/bin/ch-remote --api-socket /tmp/inst/api.sock shutdown-vmm || true\n"
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
