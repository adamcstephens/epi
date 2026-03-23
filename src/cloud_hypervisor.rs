pub const BINARY: &str = "cloud-hypervisor";
pub const CH_REMOTE_BINARY: &str = "ch-remote";

pub struct CloudHypervisorConfig<'a> {
    pub kernel: &'a str,
    pub initrd: Option<&'a str>,
    pub disk_path: &'a str,
    pub seed_iso: &'a str,
    pub cpus: u32,
    pub memory_mib: u32,
    pub cmdline: &'a str,
    pub serial_socket: &'a str,
    pub passt_socket: &'a str,
    pub fs_args: &'a [String],
    pub api_socket: Option<&'a str>,
    pub mac: &'a str,
    pub console_log: &'a str,
}

/// Build cloud-hypervisor CLI arguments from structured inputs.
pub fn build_args(config: &CloudHypervisorConfig) -> Vec<String> {
    let mut args = vec![
        "--kernel".to_string(),
        config.kernel.to_string(),
        "--disk".to_string(),
        format!(
            "path={},image_type=qcow2,backing_files=on",
            config.disk_path
        ),
        format!("path={},readonly=on", config.seed_iso),
        "--cpus".to_string(),
        format!("boot={},nested=on", config.cpus),
        "--memory".to_string(),
        format!("size={}M,shared=on", config.memory_mib),
        "--balloon".to_string(),
        "size=0,deflate_on_oom=on,free_page_reporting=on".to_string(),
        "--serial".to_string(),
        format!("socket={}", config.serial_socket),
        "--console".to_string(),
        format!("file={}", config.console_log),
        "--cmdline".to_string(),
        config.cmdline.to_string(),
        "--net".to_string(),
        format!(
            "vhost_user=true,socket={},vhost_mode=client,mac={}",
            config.passt_socket, config.mac
        ),
    ];

    if let Some(initrd) = config.initrd {
        args.push("--initramfs".to_string());
        args.push(initrd.to_string());
    }

    if !config.fs_args.is_empty() {
        args.push("--fs".to_string());
        args.extend(config.fs_args.iter().cloned());
    }

    if let Some(api_socket) = config.api_socket {
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

use std::path::Path;

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

    fn test_config() -> CloudHypervisorConfig<'static> {
        CloudHypervisorConfig {
            kernel: "/nix/store/abc/vmlinuz",
            initrd: None,
            disk_path: "/tmp/inst/disk.img",
            seed_iso: "/tmp/inst/epidata.iso",
            cpus: 2,
            memory_mib: 1024,
            cmdline: "console=hvc0 console=ttyS0 root=LABEL=nixos rw init=/nix/store/xyz/init",
            serial_socket: "/tmp/inst/serial.sock",
            passt_socket: "/tmp/inst/passt.sock",
            fs_args: &[],
            api_socket: Some("/tmp/inst/api.sock"),
            mac: "02:ab:cd:ef:01:23",
            console_log: "/tmp/inst/console.log",
        }
    }

    #[test]
    fn build_args_emits_console_file() {
        let config = test_config();
        let args = build_args(&config);
        let console_idx = args.iter().position(|a| a == "--console").unwrap();
        assert_eq!(args[console_idx + 1], "file=/tmp/inst/console.log");
    }

    #[test]
    fn build_args_passes_cmdline_through() {
        let config = test_config();
        let args = build_args(&config);
        let cmdline_idx = args.iter().position(|a| a == "--cmdline").unwrap();
        let cmdline = &args[cmdline_idx + 1];
        assert_eq!(cmdline, config.cmdline);
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

    #[test]
    fn build_args_includes_balloon() {
        let config = test_config();
        let args = build_args(&config);
        let balloon_idx = args.iter().position(|a| a == "--balloon").unwrap();
        assert_eq!(
            args[balloon_idx + 1],
            "size=0,deflate_on_oom=on,free_page_reporting=on"
        );
    }

    #[test]
    fn build_args_multiple_fs_single_flag() {
        let fs = vec![
            "tag=hostfs-0,socket=/tmp/virtiofsd-0.sock".to_string(),
            "tag=hostfs-1,socket=/tmp/virtiofsd-1.sock".to_string(),
        ];
        let config = CloudHypervisorConfig {
            fs_args: &fs,
            ..test_config()
        };
        let args = build_args(&config);

        // cloud-hypervisor takes a single --fs with variadic device specs
        let fs_count = args.iter().filter(|a| *a == "--fs").count();
        assert_eq!(fs_count, 1, "expected single --fs flag");
        let fs_idx = args.iter().position(|a| a == "--fs").unwrap();
        assert_eq!(args[fs_idx + 1], fs[0]);
        assert_eq!(args[fs_idx + 2], fs[1]);
    }

    #[test]
    fn build_args_no_fs_when_empty() {
        let config = test_config();
        let args = build_args(&config);
        assert!(!args.iter().any(|a| a == "--fs"));
    }
}
