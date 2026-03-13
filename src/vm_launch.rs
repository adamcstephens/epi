use anyhow::{Context, Result, bail};
use std::fs;
use std::net::TcpListener;
use std::path::Path;
use std::time::Duration;

use crate::instance_store::{self, Runtime};
use crate::process;
use crate::target::Descriptor;
use crate::{hooks, target};

/// Provision a new VM: resolve target, validate, launch
pub fn provision(
    instance_name: &str,
    target_str: &str,
    mounts: &[String],
    disk_size: &str,
    rebuild: bool,
) -> Result<Runtime> {
    let cache_result = target::resolve_descriptor_cached(target_str, rebuild)?;
    let desc = cache_result.descriptor();

    target::validate_descriptor(desc)?;
    target::ensure_paths_exist(desc)?;

    launch_vm(instance_name, target_str, desc, mounts, disk_size)
}

fn launch_vm(
    instance_name: &str,
    _target_str: &str,
    desc: &Descriptor,
    mounts: &[String],
    disk_size: &str,
) -> Result<Runtime> {
    let unit_id = process::generate_unit_id();
    let slice = instance_store::slice_name(instance_name, &unit_id)?;

    let result = launch_vm_inner(instance_name, desc, mounts, disk_size, &unit_id, &slice);
    if result.is_err() {
        let _ = process::stop_unit(&slice);
    }
    result
}

fn launch_vm_inner(
    instance_name: &str,
    desc: &Descriptor,
    mounts: &[String],
    disk_size: &str,
    unit_id: &str,
    slice: &str,
) -> Result<Runtime> {
    let inst_dir = instance_store::ensure_instance_dir(instance_name)?
        .canonicalize()
        .context("canonicalizing instance dir")?;

    // Check disk lock
    if let Some((owner, owner_id)) = instance_store::find_running_owner_by_disk(&desc.disk)? {
        bail!(
            "disk {} is locked by instance {owner} (unit {owner_id})",
            desc.disk
        );
    }

    // Prepare writable disk overlay
    let disk_path = inst_dir.join("disk.img");
    ensure_writable_disk(&desc.disk, &disk_path, disk_size)?;

    // Generate SSH keypair
    let ssh_key_path = inst_dir.join("id_ed25519");
    generate_ssh_key(&ssh_key_path)?;

    // Allocate SSH port
    let ssh_port = allocate_port()?;

    // Generate seed ISO
    let seed_iso = inst_dir.join("epidata.iso");
    generate_seed_iso(
        instance_name,
        &ssh_key_path,
        mounts,
        &desc.configured_users,
        &seed_iso,
    )?;

    // Clean stale sockets
    let serial_socket = inst_dir.join("serial.sock");
    if serial_socket.exists() {
        fs::remove_file(&serial_socket)?;
    }
    let serial_socket_str = serial_socket.to_string_lossy().to_string();

    let vm_unit = instance_store::vm_unit_name(instance_name, unit_id)?;

    // Start passt for networking
    let passt_unit = format!("epi-{instance_name}_{unit_id}_passt.service");
    let passt_socket = inst_dir.join("passt.sock");
    if passt_socket.exists() {
        fs::remove_file(&passt_socket)?;
    }
    start_passt(
        &passt_unit,
        slice,
        &passt_socket.to_string_lossy(),
        ssh_port,
    )?;

    let mut helper_units = vec![passt_unit.clone()];

    // Start virtiofsd for each mount
    let mut fs_args: Vec<String> = vec![];
    for (i, mount_path) in mounts.iter().enumerate() {
        let mount_dir = Path::new(mount_path);
        if !mount_dir.is_dir() {
            bail!("mount path is not a directory: {mount_path}");
        }
        let abs_mount = mount_dir
            .canonicalize()
            .with_context(|| format!("canonicalizing mount path: {mount_path}"))?;
        let vfsd_unit = format!("epi-{instance_name}_{unit_id}_virtiofsd{i}.service");
        let vfsd_socket = inst_dir.join(format!("virtiofsd-{i}.sock"));
        if vfsd_socket.exists() {
            fs::remove_file(&vfsd_socket)?;
        }
        start_virtiofsd(
            &vfsd_unit,
            slice,
            &vfsd_socket.to_string_lossy(),
            &abs_mount.to_string_lossy(),
        )?;
        helper_units.push(vfsd_unit);
        fs_args.push(format!("tag=hostfs-{i},socket={}", vfsd_socket.display()));
    }

    // Build cloud-hypervisor command
    let disk_str = disk_path.to_string_lossy().to_string();
    let seed_str = seed_iso.to_string_lossy().to_string();
    let mem_arg = format!("size={}M,shared=on", desc.memory_mib);
    let cpu_arg = format!("boot={}", desc.cpus);
    let serial_arg = format!("socket={serial_socket_str}");
    let net_arg = format!(
        "vhost_user=true,socket={},vhost_mode=client",
        passt_socket.display()
    );
    let cmdline = &desc.cmdline;

    let mut ch_args: Vec<String> = vec![
        "--kernel".to_string(),
        desc.kernel.clone(),
        "--disk".to_string(),
        format!("path={disk_str},image_type=qcow2,backing_files=on"),
        format!("path={seed_str},readonly=on"),
        "--cpus".to_string(),
        cpu_arg,
        "--memory".to_string(),
        mem_arg,
        "--serial".to_string(),
        serial_arg,
        "--console".to_string(),
        "off".to_string(),
        "--cmdline".to_string(),
        cmdline.clone(),
        "--net".to_string(),
        net_arg,
    ];

    if let Some(ref initrd) = desc.initrd {
        ch_args.push("--initramfs".to_string());
        ch_args.push(initrd.clone());
    }

    if !fs_args.is_empty() {
        ch_args.push("--fs".to_string());
        ch_args.extend(fs_args);
    }

    let ch_refs: Vec<&str> = ch_args.iter().map(|s| s.as_str()).collect();

    // Generate ExecStopPost commands to stop helper units when VM exits
    let systemctl = process::systemctl_bin();
    let exec_stop_posts: Vec<String> = helper_units
        .iter()
        .map(|u| format!("{systemctl} --user stop {u}"))
        .collect();
    let exec_stop_post_refs: Vec<&str> = exec_stop_posts.iter().map(|s| s.as_str()).collect();

    // Launch VM as systemd service
    let result = process::run_service(
        &vm_unit,
        slice,
        &exec_stop_post_refs,
        "cloud-hypervisor",
        &ch_refs,
    )?;

    if !result.success() {
        bail!(
            "failed to launch VM (exit {}): {}",
            result.status,
            result.stderr
        );
    }

    // Brief pause to catch immediate exits
    std::thread::sleep(Duration::from_millis(150));
    if !process::unit_is_active(&vm_unit)? {
        let journal = process::journal_for_unit(&vm_unit).unwrap_or_default();
        if journal.is_empty() {
            bail!("VM exited immediately after launch (no journal output)");
        } else {
            bail!("VM exited immediately after launch:\n{journal}");
        }
    }

    let runtime = Runtime {
        unit_id: unit_id.to_string(),
        serial_socket: serial_socket_str,
        disk: disk_str,
        ssh_port: Some(ssh_port),
        ssh_key_path: ssh_key_path.to_string_lossy().to_string(),
    };

    Ok(runtime)
}

pub fn wait_for_ssh(ssh_port: u16, ssh_key_path: &str, timeout_seconds: u64) -> Result<()> {
    let start = std::time::Instant::now();
    let timeout = Duration::from_secs(timeout_seconds);
    let username = std::env::var("USER").unwrap_or_else(|_| "user".to_string());
    let target = format!("{username}@127.0.0.1");

    loop {
        if start.elapsed() >= timeout {
            bail!("SSH not reachable after {timeout_seconds}s — instance may still be booting");
        }

        let port_str = ssh_port.to_string();
        let out = process::run(
            "ssh",
            &[
                "-o",
                "BatchMode=yes",
                "-o",
                "StrictHostKeyChecking=no",
                "-o",
                "UserKnownHostsFile=/dev/null",
                "-o",
                "IdentitiesOnly=yes",
                "-o",
                "ConnectTimeout=5",
                "-i",
                ssh_key_path,
                "-p",
                &port_str,
                &target,
                "true",
            ],
        )?;

        if out.success() {
            return Ok(());
        }

        std::thread::sleep(Duration::from_secs(2));
    }
}

fn ensure_writable_disk(source: &str, dest: &std::path::Path, disk_size: &str) -> Result<()> {
    if dest.exists() {
        return Ok(());
    }

    if target::is_nix_store_path(source) {
        // Create copy-on-write overlay
        let out = process::run(
            "qemu-img",
            &[
                "create",
                "-f",
                "qcow2",
                "-b",
                source,
                "-F",
                "raw",
                &dest.to_string_lossy(),
            ],
        )?;
        if !out.success() {
            bail!("qemu-img create failed: {}", out.stderr);
        }
    } else {
        fs::copy(source, dest).context("copying disk image")?;
    }

    // Resize the virtual disk — the guest grows the partition at boot
    // via boot.growPartition.
    let dest_str = dest.to_string_lossy();
    let out = process::run("qemu-img", &["resize", &dest_str, disk_size])?;
    if !out.success() {
        bail!("qemu-img resize failed: {}", out.stderr);
    }

    Ok(())
}

fn generate_ssh_key(path: &std::path::Path) -> Result<()> {
    if path.exists() {
        return Ok(());
    }
    let out = process::run(
        "ssh-keygen",
        &[
            "-t",
            "ed25519",
            "-f",
            &path.to_string_lossy(),
            "-N",
            "",
            "-q",
        ],
    )?;
    if !out.success() {
        bail!("ssh-keygen failed: {}", out.stderr);
    }
    Ok(())
}

fn allocate_port() -> Result<u16> {
    let listener = TcpListener::bind("127.0.0.1:0").context("allocating SSH port")?;
    let port = listener.local_addr()?.port();
    Ok(port)
}

fn generate_seed_iso(
    instance_name: &str,
    ssh_key_path: &std::path::Path,
    mounts: &[String],
    configured_users: &[String],
    iso_path: &std::path::Path,
) -> Result<()> {
    let staging = iso_path
        .parent()
        .ok_or_else(|| anyhow::anyhow!("iso path has no parent directory"))?
        .join("epidata");
    fs::create_dir_all(&staging)?;

    // Read public key
    let pub_key_path = format!("{}.pub", ssh_key_path.to_string_lossy());
    let pub_key = fs::read_to_string(&pub_key_path)
        .with_context(|| format!("reading public key {pub_key_path}"))?
        .trim()
        .to_string();

    // Build epi.json
    let username = std::env::var("USER").unwrap_or_else(|_| "epi".to_string());
    let mut user_obj = serde_json::json!({
        "name": username,
        "ssh_authorized_keys": [pub_key]
    });
    if !configured_users.contains(&username) {
        let uid = nix::unistd::getuid().as_raw();
        user_obj["uid"] = serde_json::json!(uid);
    }
    let epi_json = serde_json::json!({
        "hostname": instance_name,
        "user": user_obj,
        "mounts": mounts
    });

    fs::write(
        staging.join("epi.json"),
        serde_json::to_string_pretty(&epi_json)?,
    )?;

    // Copy guest-init hooks if any
    let guest_hooks = hooks::discover_guest(instance_name)?;
    if !guest_hooks.is_empty() {
        let hooks_dir = staging.join("hooks");
        fs::create_dir_all(&hooks_dir)?;
        for hook in &guest_hooks {
            let dest = hooks_dir.join(hook.file_name().ok_or_else(|| {
                anyhow::anyhow!("hook path has no file name: {}", hook.display())
            })?);
            fs::copy(hook, &dest)?;
        }
    }

    // Build ISO with xorriso
    let out = process::run(
        "xorriso",
        &[
            "-as",
            "mkisofs",
            "-o",
            &iso_path.to_string_lossy(),
            "-V",
            "epidata",
            "-R",
            "-J",
            &staging.to_string_lossy(),
        ],
    )?;
    if !out.success() {
        bail!("xorriso failed: {}", out.stderr);
    }

    // Clean up staging
    fs::remove_dir_all(&staging)?;

    Ok(())
}

fn start_passt(unit_name: &str, slice: &str, socket_path: &str, ssh_port: u16) -> Result<()> {
    let tcp_fwd = format!("{ssh_port}:22");
    let out = process::run_helper(
        unit_name,
        slice,
        "passt",
        &[
            "--foreground",
            "--vhost-user",
            "--socket-path",
            socket_path,
            "--tcp-ports",
            &tcp_fwd,
        ],
    )?;
    if !out.success() {
        bail!("failed to start passt: {}", out.stderr);
    }
    wait_for_socket(socket_path, 2000)?;
    Ok(())
}

fn start_virtiofsd(
    unit_name: &str,
    slice: &str,
    socket_path: &str,
    shared_dir: &str,
) -> Result<()> {
    let out = process::run_helper(
        unit_name,
        slice,
        "virtiofsd",
        &[
            "--socket-path",
            socket_path,
            "--shared-dir",
            shared_dir,
            "--announce-submounts",
        ],
    )?;
    if !out.success() {
        bail!("failed to start virtiofsd: {}", out.stderr);
    }
    wait_for_socket(socket_path, 2000)?;
    Ok(())
}

fn wait_for_socket(path: &str, max_wait_ms: u64) -> Result<()> {
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

/// Stop all units for an instance
pub fn stop_instance(instance_name: &str) -> Result<()> {
    let runtime = instance_store::find_runtime(instance_name)?
        .ok_or_else(|| anyhow::anyhow!("instance {instance_name} has no runtime"))?;

    let slice = instance_store::slice_name(instance_name, &runtime.unit_id)?;

    // Stopping the slice stops all units in it (VM + helpers)
    process::stop_unit(&slice)?;

    instance_store::clear_runtime(instance_name)?;
    Ok(())
}
