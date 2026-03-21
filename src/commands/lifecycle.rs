use anyhow::Result;

use epi::{config, console, gcroots, hooks, instance_store, ssh, target, ui, vm_launch};

use super::info::cmd_info;

pub fn cmd_launch(
    instance: &str,
    resolved: &config::Resolved,
    attach_console: bool,
    rebuild: bool,
    no_provision: bool,
    wait_timeout: u64,
) -> Result<()> {
    // Check if already running
    if instance_store::instance_is_running(instance)? {
        ui::info(&format!("Instance {instance} is already running"));
        if attach_console {
            return console::attach(instance, None, None);
        }
        return cmd_info(instance);
    }

    // If instance exists but stale, stop it first
    if instance_store::find_runtime(instance)?.is_some() {
        ui::info(&format!(
            "Instance {instance} has stale runtime, cleaning up"
        ));
        let _ = vm_launch::stop_instance(instance);
    }

    let pre_existing = instance_store::find(instance)?.is_some();
    let project_dir = config::project_dir()?;
    let project_dir_ref = project_dir.clone();
    instance_store::save_state(
        instance,
        &instance_store::InstanceState {
            target: resolved.target.clone(),
            runtime: None,
            mounts: instance_store::canonicalize_mounts(&resolved.mounts),
            project_dir,
            disk_size: resolved.disk_size.clone(),
            cpus: resolved.cpus,
            memory_mib: resolved.memory,
            port_specs: resolved.ports.clone(),
            descriptor: None,
        },
    )?;

    let params = vm_launch::ProvisionParams {
        instance_name: instance,
        target_str: &resolved.target,
        mounts: &resolved.mounts,
        disk_size: &resolved.disk_size,
        rebuild,
        cpus: resolved.cpus,
        memory_mib: resolved.memory,
        port_specs: &resolved.ports,
    };

    let (runtime, descriptor) = match prepare_and_provision(&params) {
        Ok(r) => r,
        Err(e) => {
            if pre_existing {
                let _ = instance_store::clear_runtime(instance);
            } else {
                let _ = instance_store::remove(instance);
            }
            return Err(e);
        }
    };

    let ssh_key_path = runtime.ssh_key_path.clone();
    let ssh_port = runtime.ssh_port;

    instance_store::set_provisioned(instance, runtime, Some(descriptor))?;

    // Write SSH config immediately — port and key are known
    if let Some(ssh_port) = ssh_port {
        ssh::generate_config(
            &ssh::config_path(instance),
            instance,
            ssh_port,
            &ssh::user(),
            std::path::Path::new(&ssh_key_path),
            None,
        )?;
    }

    let no_provision = no_provision
        || std::env::var("EPI_NO_PROVISION")
            .map(|v| v == "true" || v == "1")
            .unwrap_or(false);

    if attach_console {
        // Run SSH wait + hooks in background so console attaches immediately
        // Skip spinners — raw terminal mode would be corrupted
        let wait_handle = if let Some(ssh_port) = ssh_port.filter(|_| !no_provision) {
            let inst = instance.to_string();
            let key = ssh_key_path.clone();
            let tgt = resolved.target.clone();
            let pdir = project_dir_ref.clone();
            let timeout = std::env::var("EPI_WAIT_TIMEOUT_SECONDS")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(wait_timeout);
            Some(std::thread::spawn(move || -> Result<()> {
                let config = ssh::config_path(&inst);
                eprintln!("Waiting for SSH...");
                ssh::wait_for_ssh(&config, &inst, timeout)?;
                ssh::trust_host_key(&inst, ssh_port, &ssh::user(), std::path::Path::new(&key))?;
                eprintln!("Instance {inst} is ready");
                run_post_launch_hooks(&inst, &tgt, ssh_port, &key, pdir)?;
                Ok(())
            }))
        } else {
            None
        };

        console::attach(instance, None, None)?;

        if let Some(handle) = wait_handle {
            let _ = handle.join();
        }
    } else if let Some(ssh_port) = ssh_port.filter(|_| !no_provision) {
        let timeout = std::env::var("EPI_WAIT_TIMEOUT_SECONDS")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(wait_timeout);

        wait_and_trust_ssh(instance, ssh_port, &ssh_key_path, timeout)?;

        run_post_launch_hooks(
            instance,
            &resolved.target,
            ssh_port,
            &ssh_key_path,
            project_dir_ref,
        )?;
    }

    Ok(())
}

fn prepare_and_provision(
    params: &vm_launch::ProvisionParams,
) -> Result<(instance_store::Runtime, target::Descriptor)> {
    let group = ui::Group::start("Preparing");

    // Resolve target descriptor
    let cache_result = match resolve_with_ui(&group, params.target_str, params.rebuild) {
        Ok(r) => r,
        Err(e) => {
            group.fail("Preparation failed");
            return Err(e);
        }
    };
    let desc = cache_result.descriptor().clone();

    target::validate_descriptor(&desc)?;

    // Show artifact status (cached or building)
    let all = target::all_artifacts(&desc);
    let missing = target::missing_artifacts(&desc);
    let dim = ::console::Style::new().for_stderr().dim();
    for artifact in &all {
        if missing.iter().any(|m| m.kind == artifact.kind) {
            let label = format!(
                "Building {} {}",
                artifact.kind.label(),
                dim.apply_to(&artifact.store_path)
            );
            let step = group.step(&label);
            match target::build_artifact(params.target_str, artifact) {
                Ok(()) => step.finish(&format!(
                    "Built {} {}",
                    artifact.kind.label(),
                    dim.apply_to(&artifact.store_path)
                )),
                Err(e) => {
                    step.fail(&format!("Building {} failed", artifact.kind.label()));
                    group.fail("Preparation failed");
                    return Err(e);
                }
            }
        } else {
            group.cached(&format!(
                "Cached {} {}",
                artifact.kind.label(),
                dim.apply_to(&artifact.store_path)
            ));
        }
    }

    // Build hook store paths if needed
    target::ensure_hook_paths(params.target_str, &desc)?;

    // Create GC roots to prevent nix-collect-garbage from sweeping store paths
    gcroots::create(params.instance_name, &desc)?;

    group.finish("Prepared");

    // Launch VM
    let step = ui::Step::start(&format!("Launching {}", params.instance_name));
    match vm_launch::provision_with_descriptor(params, &desc) {
        Ok(r) => {
            step.finish(&format!("Launched {}", params.instance_name));
            Ok((r, desc))
        }
        Err(e) => {
            step.fail(&format!("Launching {} failed", params.instance_name));
            Err(e)
        }
    }
}

fn resolve_with_ui(
    group: &ui::Group,
    target_str: &str,
    rebuild: bool,
) -> Result<target::CacheResult> {
    let step = group.step(&format!("Evaluating {target_str}"));
    let result = target::resolve_descriptor_cached(target_str, rebuild)?;
    match &result {
        target::CacheResult::Cached(_) => {
            step.finish_cached(&format!("Cached {target_str}"));
        }
        target::CacheResult::Resolved(_) => {
            step.finish(&format!("Evaluated {target_str}"));
        }
    }
    Ok(result)
}

/// Launch a VM from stored instance state and a descriptor.
///
/// Builds ProvisionParams from the state, launches the VM, saves runtime,
/// and writes the initial SSH config. Returns (ssh_port, ssh_key_path).
fn launch_with_descriptor(
    instance: &str,
    state: &instance_store::InstanceState,
    desc: &target::Descriptor,
) -> Result<(Option<u16>, String)> {
    let mounts = state.mounts.clone();
    let params = vm_launch::ProvisionParams {
        instance_name: instance,
        target_str: &state.target,
        mounts: &mounts,
        disk_size: &state.disk_size,
        rebuild: false,
        cpus: state.cpus,
        memory_mib: state.memory_mib,
        port_specs: &state.port_specs,
    };

    let step = ui::Step::start(&format!("Launching {instance}"));
    let runtime = match vm_launch::provision_with_descriptor(&params, desc) {
        Ok(r) => {
            step.finish(&format!("Launched {instance}"));
            r
        }
        Err(e) => {
            step.fail(&format!("Launching {instance} failed"));
            return Err(e);
        }
    };

    let ssh_key_path = runtime.ssh_key_path.clone();
    let ssh_port = runtime.ssh_port;

    instance_store::set_provisioned(instance, runtime, Some(desc.clone()))?;

    if let Some(ssh_port) = ssh_port {
        ssh::generate_config(
            &ssh::config_path(instance),
            instance,
            ssh_port,
            &ssh::user(),
            std::path::Path::new(&ssh_key_path),
            None,
        )?;
    }

    Ok((ssh_port, ssh_key_path))
}

fn run_pre_stop_hooks(
    instance: &str,
    target_str: &str,
    ssh_port: u16,
    ssh_key_path: &str,
    project_dir: Option<String>,
) -> Result<()> {
    let desc_hooks = target::resolve_descriptor_cached(target_str, false)
        .map(|c| c.descriptor().hooks.pre_stop_scripts())
        .unwrap_or_default();

    let hook_scripts = hooks::discover(instance, &desc_hooks, "pre-stop")?;
    if !hook_scripts.is_empty() {
        let env = hooks::HookEnv {
            instance_name: instance.to_string(),
            ssh_port,
            ssh_key_path: ssh_key_path.to_string(),
            ssh_user: ssh::user(),
            state_dir: instance_store::state_dir().to_string_lossy().to_string(),
            project_dir,
        };
        hooks::execute(&env, &hook_scripts)?;
    }
    Ok(())
}

fn wait_and_trust_ssh(
    instance: &str,
    ssh_port: u16,
    ssh_key_path: &str,
    wait_timeout: u64,
) -> Result<()> {
    let config = ssh::config_path(instance);
    let step = ui::Step::start("Waiting for SSH");
    match ssh::wait_for_ssh(&config, instance, wait_timeout) {
        Ok(()) => step.finish(&format!("Instance {instance} is ready")),
        Err(e) => {
            step.fail("SSH wait failed");
            return Err(e);
        }
    }

    ssh::trust_host_key(
        instance,
        ssh_port,
        &ssh::user(),
        std::path::Path::new(ssh_key_path),
    )?;

    Ok(())
}

fn run_post_launch_hooks(
    instance: &str,
    target_str: &str,
    ssh_port: u16,
    ssh_key_path: &str,
    project_dir: Option<String>,
) -> Result<()> {
    let desc_hooks = target::resolve_descriptor_cached(target_str, false)
        .map(|c| c.descriptor().hooks.post_launch_scripts())
        .unwrap_or_default();

    let hook_scripts = hooks::discover(instance, &desc_hooks, "post-launch")?;
    if !hook_scripts.is_empty() {
        let env = hooks::HookEnv {
            instance_name: instance.to_string(),
            ssh_port,
            ssh_key_path: ssh_key_path.to_string(),
            ssh_user: ssh::user(),
            state_dir: instance_store::state_dir().to_string_lossy().to_string(),
            project_dir,
        };
        hooks::execute(&env, &hook_scripts)?;
    }
    Ok(())
}

pub fn cmd_start(
    instance: &str,
    attach_console: bool,
    no_provision: bool,
    wait_timeout: u64,
) -> Result<()> {
    if instance_store::instance_is_running(instance)? {
        ui::info(&format!("Instance {instance} is already running"));
        if attach_console {
            return console::attach(instance, None, None);
        }
        return Ok(());
    }

    let state = instance_store::load_state(instance)?
        .ok_or_else(|| anyhow::anyhow!("instance {instance} not found — use 'launch' first"))?;

    // Use stored descriptor if available, otherwise resolve fresh
    let desc = match &state.descriptor {
        Some(desc) => {
            ui::info(&format!("Using stored descriptor for {}", state.target));
            desc.clone()
        }
        None => {
            let cache_result = target::resolve_descriptor_cached(&state.target, false)?;
            cache_result.descriptor().clone()
        }
    };

    target::validate_descriptor(&desc)?;

    // Build any missing artifacts
    let missing = target::missing_artifacts(&desc);
    for artifact in &missing {
        target::build_artifact(&state.target, artifact)?;
    }
    target::ensure_hook_paths(&state.target, &desc)?;

    // Create GC roots
    gcroots::create(instance, &desc)?;

    let (ssh_port, ssh_key_path) = launch_with_descriptor(instance, &state, &desc)?;

    if let Some(ssh_port) = ssh_port.filter(|_| !no_provision) {
        wait_and_trust_ssh(instance, ssh_port, &ssh_key_path, wait_timeout)?;
    }

    if attach_console {
        console::attach(instance, None, None)?;
    }

    Ok(())
}

pub fn cmd_stop(instance: &str) -> Result<()> {
    if !instance_store::instance_is_running(instance)? {
        if instance_store::find_runtime(instance)?.is_some() {
            instance_store::clear_runtime(instance)?;
            ui::info(&format!(
                "Instance {instance} was already stopped (stale runtime cleared)"
            ));
        } else {
            ui::info(&format!("Instance {instance} is not running"));
        }
        return Ok(());
    }

    // Run pre-stop hooks
    let state = instance_store::load_state(instance)?;
    if let Some(ref st) = state
        && let Some(ref rt) = st.runtime
        && let Some(ssh_port) = rt.ssh_port
    {
        run_pre_stop_hooks(
            instance,
            &st.target,
            ssh_port,
            &rt.ssh_key_path,
            st.project_dir.clone(),
        )?;
    }

    let step = ui::Step::start(&format!("Stopping {instance}"));
    vm_launch::stop_instance(instance)?;
    step.finish(&format!("Stopped {instance}"));
    Ok(())
}

pub fn cmd_rm(instance: &str, force: bool) -> Result<()> {
    let exists = instance_store::find(instance)?.is_some();

    if !exists {
        if force {
            ui::info(&format!("No instance {instance} found"));
            return Ok(());
        }
        anyhow::bail!("instance {instance} not found");
    }

    let running = instance_store::instance_is_running(instance)?;

    if running && !force {
        anyhow::bail!("instance {instance} is running — use --force to terminate and remove");
    }

    if running {
        let step = ui::Step::start(&format!("Terminating {instance}"));
        vm_launch::stop_instance(instance)?;
        step.finish(&format!("Terminated {instance}"));
    }

    let step = ui::Step::start(&format!("Removing {instance}"));
    instance_store::remove(instance)?;
    step.finish(&format!("Removed {instance}"));
    Ok(())
}

#[derive(Clone, PartialEq, Eq, clap::ValueEnum)]
pub enum UpgradeMode {
    Switch,
    Boot,
}

pub fn cmd_upgrade(instance: &str, mode: UpgradeMode, wait_timeout: u64) -> Result<()> {
    // Instance must be running
    if !instance_store::instance_is_running(instance)? {
        anyhow::bail!("instance {instance} is not running — upgrade requires a running instance");
    }

    let state = instance_store::load_state(instance)?
        .ok_or_else(|| anyhow::anyhow!("instance {instance} not found"))?;

    let runtime = state
        .runtime
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("instance {instance} has no runtime"))?;

    let ssh_port = runtime
        .ssh_port
        .ok_or_else(|| anyhow::anyhow!("instance {instance} has no SSH port"))?;
    let ssh_key_path = runtime.ssh_key_path.clone();

    // Step 1: Re-evaluate target (force cache bust)
    let group = ui::Group::start("Preparing upgrade");
    let cache_result = resolve_with_ui(&group, &state.target, true)?;
    let mut new_desc = cache_result.descriptor().clone();
    target::validate_descriptor(&new_desc)?;

    // Preserve the original disk path — the overlay is backed by the old image,
    // and we don't build a new disk image during upgrade.
    if let Some(ref old_desc) = state.descriptor {
        new_desc.disk = old_desc.disk.clone();
    }

    // Step 2: Build toplevel (includes kernel + initrd in its closure)
    let step = group.step("Building toplevel");
    let toplevel = match target::build_toplevel(&state.target) {
        Ok(t) => {
            step.finish("Built toplevel");
            t
        }
        Err(e) => {
            step.fail("Building toplevel failed");
            group.fail("Upgrade preparation failed");
            return Err(e);
        }
    };

    // Verify kernel/initrd exist (part of toplevel closure)
    for artifact in &target::upgrade_artifacts(&new_desc) {
        if !std::path::Path::new(&artifact.store_path).exists() {
            group.fail("Upgrade preparation failed");
            anyhow::bail!(
                "{} not found after build: {}",
                artifact.kind.label(),
                artifact.store_path
            );
        }
    }

    // Build hook store paths if needed
    target::ensure_hook_paths(&state.target, &new_desc)?;

    group.finish("Prepared upgrade");

    // Step 3: Copy toplevel closure to guest
    let step = ui::Step::start("Copying closure to guest");
    match ssh::nix_copy_closure(instance, &toplevel) {
        Ok(()) => step.finish("Copied closure to guest"),
        Err(e) => {
            step.fail("Failed to copy closure");
            return Err(e);
        }
    }

    // Step 4: Run switch-to-configuration on guest
    let switch_action = match mode {
        UpgradeMode::Switch => "switch",
        UpgradeMode::Boot => "boot",
    };
    let step = ui::Step::start(&format!("Activating configuration ({switch_action})"));
    let switch_cmd = format!("sudo {toplevel}/bin/switch-to-configuration {switch_action}");
    match ssh::run_on_guest(instance, &switch_cmd) {
        Ok(()) => step.finish(&format!("Activated configuration ({switch_action})")),
        Err(e) => {
            step.fail("Activation failed");
            return Err(e);
        }
    }

    match mode {
        UpgradeMode::Switch => {
            // Update gcroots first, then state — if gcroots fails we don't
            // commit a descriptor whose paths aren't rooted.
            gcroots::create(instance, &new_desc)?;
            instance_store::update_descriptor(instance, new_desc)?;
        }
        UpgradeMode::Boot => {
            run_pre_stop_hooks(
                instance,
                &state.target,
                ssh_port,
                &ssh_key_path,
                state.project_dir.clone(),
            )?;

            // Stop VM
            let step = ui::Step::start(&format!("Stopping {instance} for reboot"));
            vm_launch::stop_instance(instance)?;
            step.finish(&format!("Stopped {instance}"));

            // Update descriptor and GC roots before restart
            instance_store::update_descriptor(instance, new_desc.clone())?;
            gcroots::create(instance, &new_desc)?;

            let (new_ssh_port, new_ssh_key_path) =
                launch_with_descriptor(instance, &state, &new_desc)?;

            if let Some(new_ssh_port) = new_ssh_port {
                let timeout = std::env::var("EPI_WAIT_TIMEOUT_SECONDS")
                    .ok()
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(wait_timeout);

                wait_and_trust_ssh(instance, new_ssh_port, &new_ssh_key_path, timeout)?;

                run_post_launch_hooks(
                    instance,
                    &state.target,
                    new_ssh_port,
                    &new_ssh_key_path,
                    state.project_dir.clone(),
                )?;
            }
        }
    }

    Ok(())
}

pub fn cmd_rebuild(instance: &str) -> Result<()> {
    let state = instance_store::load_state(instance)?
        .ok_or_else(|| anyhow::anyhow!("instance {instance} not found"))?;

    let was_running = instance_store::instance_is_running(instance)?;
    if was_running {
        let step = ui::Step::start(&format!("Stopping {instance} for rebuild"));
        vm_launch::stop_instance(instance)?;
        step.finish(&format!("Stopped {instance}"));
    }

    // Remove disk to force fresh overlay
    let disk_path = instance_store::instance_path(instance, "disk.img");
    if disk_path.exists() {
        std::fs::remove_file(&disk_path)?;
    }

    let mounts = state.mounts.clone();
    let params = vm_launch::ProvisionParams {
        instance_name: instance,
        target_str: &state.target,
        mounts: &mounts,
        disk_size: &state.disk_size,
        rebuild: true,
        cpus: state.cpus,
        memory_mib: state.memory_mib,
        port_specs: &state.port_specs,
    };
    let (runtime, descriptor) = prepare_and_provision(&params)?;

    let ssh_key_path = runtime.ssh_key_path.clone();
    let ssh_port = runtime.ssh_port;

    instance_store::set_provisioned(instance, runtime, Some(descriptor))?;

    if let Some(ssh_port) = ssh_port {
        ssh::generate_config(
            &ssh::config_path(instance),
            instance,
            ssh_port,
            &ssh::user(),
            std::path::Path::new(&ssh_key_path),
            None,
        )?;
    }

    if let Some(ssh_port) = ssh_port {
        wait_and_trust_ssh(instance, ssh_port, &ssh_key_path, 120)?;

        run_post_launch_hooks(
            instance,
            &state.target,
            ssh_port,
            &ssh_key_path,
            state.project_dir.clone(),
        )?;
    }

    Ok(())
}
