use anyhow::{Context, Result, bail};
use std::fs;
use std::net::TcpListener;
use std::path::{Path, PathBuf};

use crate::backend::{self, LaunchSpec, PortMapping, RunningInstance, SharedDir};
use crate::hooks;
use crate::instance_store;
use crate::process;
use crate::target::{self, Descriptor};

pub struct LaunchConfig<'a> {
    pub instance_name: &'a str,
    pub desc: &'a Descriptor,
    pub mounts: &'a [String],
    pub disk_size: &'a str,
    pub cpus: u32,
    pub memory_mib: u32,
    pub port_specs: &'a [String],
}

pub struct ProvisionParams<'a> {
    pub instance_name: &'a str,
    pub target_str: &'a str,
    pub mounts: &'a [String],
    pub disk_size: &'a str,
    pub rebuild: bool,
    pub cpus: u32,
    pub memory_mib: u32,
    pub port_specs: &'a [String],
}

/// Provision a new VM: resolve target, validate, launch
pub fn provision(params: &ProvisionParams) -> Result<RunningInstance> {
    let cache_result = target::resolve_descriptor_cached(params.target_str, params.rebuild)?;
    let desc = cache_result.descriptor();

    target::ensure_paths_exist(params.target_str, desc)?;

    provision_with_descriptor(params, desc)
}

/// Provision a VM with an already-resolved descriptor (skips resolution/build).
pub fn provision_with_descriptor(
    params: &ProvisionParams,
    desc: &Descriptor,
) -> Result<RunningInstance> {
    let config = LaunchConfig {
        instance_name: params.instance_name,
        desc,
        mounts: params.mounts,
        disk_size: params.disk_size,
        cpus: params.cpus,
        memory_mib: params.memory_mib,
        port_specs: params.port_specs,
    };

    launch_vm(&config)
}

fn launch_vm(config: &LaunchConfig) -> Result<RunningInstance> {
    let instance_name = config.instance_name;
    let desc = config.desc;

    let inst_dir = instance_store::ensure_instance_dir(instance_name)?
        .canonicalize()
        .context("canonicalizing instance dir")?;

    // Check disk lock
    if let Some((owner, owner_rt)) = backend::find_running_owner_by_disk(&desc.disk)? {
        let owner_id = match &owner_rt.backend {
            crate::backend::BackendState::CloudHypervisor(ch) => format!("unit {}", ch.unit_id),
            crate::backend::BackendState::Vz(vz) => format!("pid {}", vz.pid),
        };
        bail!(
            "disk {} is locked by instance {owner} ({owner_id})",
            desc.disk
        );
    }

    // Generate SSH keypair
    let ssh_key_path = inst_dir.join("id_ed25519");
    generate_ssh_key(&ssh_key_path)?;
    let ssh_pubkey = read_ssh_pubkey(&ssh_key_path)?;

    // Allocate SSH port
    let ssh_port = allocate_port()?;

    // Parse and allocate user-specified port mappings
    let mut port_forwards: Vec<PortMapping> = vec![];
    for spec in config.port_specs {
        let (host, guest) = instance_store::parse_port_mapping(spec)?;
        let host = if host == 0 { allocate_port()? } else { host };
        port_forwards.push(PortMapping {
            host,
            guest,
            protocol: "tcp".to_string(),
        });
    }

    // Generate seed ISO
    let epidata = inst_dir.join("epidata.iso");
    generate_seed_iso(
        instance_name,
        &ssh_key_path,
        config.mounts,
        &desc.configured_users,
        &epidata,
    )?;

    // Canonicalize mount paths into shares
    let mut shares = Vec::with_capacity(config.mounts.len());
    for (i, mount_path) in config.mounts.iter().enumerate() {
        let mount_dir = Path::new(mount_path);
        if !mount_dir.is_dir() {
            bail!("mount path is not a directory: {mount_path}");
        }
        let abs_mount = mount_dir
            .canonicalize()
            .with_context(|| format!("canonicalizing mount path: {mount_path}"))?;
        shares.push(SharedDir {
            tag: format!("hostfs-{i}"),
            host_path: abs_mount,
            read_only: false,
        });
    }

    let spec = LaunchSpec {
        id: instance_name.to_string(),
        kernel: PathBuf::from(&desc.kernel),
        initrd: desc.initrd.as_ref().map(PathBuf::from),
        cmdline: desc.cmdline.clone(),
        root_disk: PathBuf::from(&desc.disk),
        epidata,
        shares,
        cpus: config.cpus,
        memory_mib: config.memory_mib,
        ssh_pubkey,
        ssh_port,
        port_forwards,
        disk_size: config.disk_size.to_string(),
        instance_dir: inst_dir.clone(),
    };

    backend::platform_backend().launch(&spec)
}

fn read_ssh_pubkey(ssh_key_path: &Path) -> Result<String> {
    let pub_key_path = format!("{}.pub", ssh_key_path.display());
    Ok(fs::read_to_string(&pub_key_path)
        .with_context(|| format!("reading public key {pub_key_path}"))?
        .trim()
        .to_string())
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
    let canonical_mounts: Vec<String> = mounts
        .iter()
        .map(|m| {
            Path::new(m)
                .canonicalize()
                .map(|p| p.to_string_lossy().to_string())
                .unwrap_or_else(|_| m.clone())
        })
        .collect();

    let host_home = std::env::var("HOME").ok().and_then(|home| {
        Path::new(&home)
            .canonicalize()
            .ok()
            .map(|p| p.to_string_lossy().to_string())
    });

    let epi_json = serde_json::json!({
        "hostname": instance_name,
        "user": user_obj,
        "host_home": host_home,
        "mounts": canonical_mounts
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
    process::require_binary("xorriso", "xorriso")?;
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
