use crate::process;

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
        format!("vhost_user=true,socket={passt_socket},vhost_mode=client"),
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
/// ExecStopPost always cleans up helper units regardless.
pub fn service_properties(api_socket: Option<&str>, helper_units: &[String]) -> Vec<String> {
    let systemctl = process::systemctl_bin();
    let mut props = Vec::new();

    if let Some(api_socket) = api_socket {
        props.push(format!(
            "ExecStop={CH_REMOTE_BINARY} --api-socket {api_socket} power-button"
        ));
        props.push("ExecStop=timeout 15 tail --pid=$MAINPID -f /dev/null".to_string());
        props.push(format!(
            "ExecStop={CH_REMOTE_BINARY} --api-socket {api_socket} shutdown-vmm"
        ));
        props.push("TimeoutStopSec=20".to_string());
    }

    for unit in helper_units {
        props.push(format!("ExecStopPost={systemctl} --user stop {unit}"));
        props.push(format!("After={unit}"));
    }

    props
}
