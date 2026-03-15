use anyhow::Result;

use epi::{config, console, hooks, instance_store, ssh, target, ui, vm_launch};

use super::info::cmd_info;

pub fn cmd_launch(
    instance: &str,
    resolved: &config::Resolved,
    attach_console: bool,
    rebuild: bool,
    no_wait: bool,
    wait_timeout: u64,
) -> Result<()> {
    // Check if already running
    if instance_store::instance_is_running(instance)? {
        ui::info(&format!("instance {instance} is already running"));
        if attach_console {
            return console::attach(instance, None, None);
        }
        return cmd_info(instance);
    }

    // If instance exists but stale, stop it first
    if instance_store::find_runtime(instance)?.is_some() {
        ui::info(&format!(
            "instance {instance} has stale runtime, cleaning up"
        ));
        let _ = vm_launch::stop_instance(instance);
    }

    let pre_existing = instance_store::find(instance)?.is_some();
    let project_dir = config::project_dir()?;
    instance_store::save_state(
        instance,
        &instance_store::InstanceState {
            target: resolved.target.clone(),
            runtime: None,
            mounts: instance_store::canonicalize_mounts(&resolved.mounts),
            project_dir,
            disk_size: Some(resolved.disk_size.clone()),
            cpus: resolved.cpus,
            memory_mib: resolved.memory,
            port_specs: Some(resolved.ports.clone()),
        },
    )?;

    let step = ui::Step::start(&format!("Provisioning {instance}"));

    let runtime = match vm_launch::provision(&vm_launch::ProvisionParams {
        instance_name: instance,
        target_str: &resolved.target,
        mounts: &resolved.mounts,
        disk_size: &resolved.disk_size,
        rebuild,
        cpus: resolved.cpus,
        memory_mib: resolved.memory,
        port_specs: &resolved.ports,
    }) {
        Ok(r) => {
            step.finish(&format!("Provisioned {instance}"));
            r
        }
        Err(e) => {
            step.fail(&format!("Provisioning {instance} failed"));
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

    instance_store::set_provisioned(instance, runtime)?;

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

    let no_wait = no_wait
        || std::env::var("EPI_NO_WAIT")
            .map(|v| v == "true" || v == "1")
            .unwrap_or(false);

    if attach_console {
        // Run SSH wait + hooks in background so console attaches immediately
        // Skip spinners — raw terminal mode would be corrupted
        let wait_handle = if let Some(ssh_port) = ssh_port.filter(|_| !no_wait) {
            let inst = instance.to_string();
            let key = ssh_key_path.clone();
            let tgt = resolved.target.clone();
            let timeout = std::env::var("EPI_WAIT_TIMEOUT_SECONDS")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(wait_timeout);
            Some(std::thread::spawn(move || -> Result<()> {
                let config = ssh::config_path(&inst);
                eprintln!("waiting for SSH on port {ssh_port}...");
                ssh::wait_for_ssh(&config, &inst, timeout)?;
                ssh::trust_host_key(&inst, ssh_port, &ssh::user(), std::path::Path::new(&key))?;
                eprintln!("instance {inst} is ready (ssh port {ssh_port})");
                run_post_launch_hooks(&inst, &tgt, ssh_port, &key)?;
                Ok(())
            }))
        } else {
            None
        };

        console::attach(instance, None, None)?;

        if let Some(handle) = wait_handle {
            let _ = handle.join();
        }
    } else if let Some(ssh_port) = ssh_port.filter(|_| !no_wait) {
        let timeout = std::env::var("EPI_WAIT_TIMEOUT_SECONDS")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(wait_timeout);

        let config = ssh::config_path(instance);
        let step = ui::Step::start("Waiting for SSH");
        match ssh::wait_for_ssh(&config, instance, timeout) {
            Ok(()) => step.finish(&format!(
                "instance {instance} is ready (ssh port {ssh_port})"
            )),
            Err(e) => {
                step.fail("SSH wait failed");
                return Err(e);
            }
        }

        ssh::trust_host_key(
            instance,
            ssh_port,
            &ssh::user(),
            std::path::Path::new(&ssh_key_path),
        )?;

        run_post_launch_hooks(instance, &resolved.target, ssh_port, &ssh_key_path)?;
    }

    Ok(())
}

fn run_post_launch_hooks(
    instance: &str,
    target_str: &str,
    ssh_port: u16,
    ssh_key_path: &str,
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
        };
        hooks::execute(&env, &hook_scripts)?;
    }
    Ok(())
}

pub fn cmd_start(
    instance: &str,
    attach_console: bool,
    no_wait: bool,
    wait_timeout: u64,
) -> Result<()> {
    if instance_store::instance_is_running(instance)? {
        ui::info(&format!("instance {instance} is already running"));
        if attach_console {
            return console::attach(instance, None, None);
        }
        return Ok(());
    }

    let state = instance_store::load_state(instance)?
        .ok_or_else(|| anyhow::anyhow!("instance {instance} not found — use 'launch' first"))?;

    let mounts = state.mounts.clone();

    let step = ui::Step::start(&format!("Starting {instance}"));
    let port_specs = state
        .port_specs
        .clone()
        .or_else(|| config::load_project().ok().flatten().and_then(|c| c.ports))
        .unwrap_or_default();
    let disk_size = state.disk_size.clone().unwrap_or_else(|| "40G".into());
    let runtime = vm_launch::provision(&vm_launch::ProvisionParams {
        instance_name: instance,
        target_str: &state.target,
        mounts: &mounts,
        disk_size: &disk_size,
        rebuild: false,
        cpus: state.cpus,
        memory_mib: state.memory_mib,
        port_specs: &port_specs,
    })?;
    step.finish(&format!("Started {instance}"));

    let ssh_key_path = runtime.ssh_key_path.clone();
    let ssh_port = runtime.ssh_port;

    instance_store::set_provisioned(instance, runtime)?;

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

    if let Some(ssh_port) = ssh_port.filter(|_| !no_wait) {
        let config = ssh::config_path(instance);
        let step = ui::Step::start("Waiting for SSH");
        ssh::wait_for_ssh(&config, instance, wait_timeout)?;
        step.finish(&format!(
            "instance {instance} is ready (ssh port {ssh_port})"
        ));

        ssh::trust_host_key(
            instance,
            ssh_port,
            &ssh::user(),
            std::path::Path::new(&ssh_key_path),
        )?;
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
                "stop: instance {instance} was already stopped (stale runtime cleared)"
            ));
        } else {
            ui::info(&format!("instance {instance} is not running"));
        }
        return Ok(());
    }

    // Run pre-stop hooks
    let state = instance_store::load_state(instance)?;
    if let Some(ref st) = state
        && let Some(ref rt) = st.runtime
        && let Some(ssh_port) = rt.ssh_port
    {
        let desc_hooks = target::resolve_descriptor_cached(&st.target, false)
            .map(|c| c.descriptor().hooks.pre_stop_scripts())
            .unwrap_or_default();

        let hook_scripts = hooks::discover(instance, &desc_hooks, "pre-stop")?;
        if !hook_scripts.is_empty() {
            let env = hooks::HookEnv {
                instance_name: instance.to_string(),
                ssh_port,
                ssh_key_path: rt.ssh_key_path.clone(),
                ssh_user: ssh::user(),
                state_dir: instance_store::state_dir().to_string_lossy().to_string(),
            };
            hooks::execute(&env, &hook_scripts)?;
        }
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
            ui::info(&format!("no instance {instance} found"));
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

    let step = ui::Step::start(&format!("Rebuilding {instance}"));
    let mounts = state.mounts.clone();
    let port_specs = state
        .port_specs
        .clone()
        .or_else(|| config::load_project().ok().flatten().and_then(|c| c.ports))
        .unwrap_or_default();
    let disk_size = state.disk_size.clone().unwrap_or_else(|| "40G".into());
    let runtime = vm_launch::provision(&vm_launch::ProvisionParams {
        instance_name: instance,
        target_str: &state.target,
        mounts: &mounts,
        disk_size: &disk_size,
        rebuild: true,
        cpus: state.cpus,
        memory_mib: state.memory_mib,
        port_specs: &port_specs,
    })?;
    step.finish(&format!("Rebuilt {instance}"));

    let ssh_key_path = runtime.ssh_key_path.clone();
    let ssh_port = runtime.ssh_port;

    instance_store::set_provisioned(instance, runtime)?;

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
        let config = ssh::config_path(instance);
        let step = ui::Step::start("Waiting for SSH");
        ssh::wait_for_ssh(&config, instance, 120)?;
        step.finish(&format!(
            "instance {instance} rebuilt and ready (ssh port {ssh_port})"
        ));

        ssh::trust_host_key(
            instance,
            ssh_port,
            &ssh::user(),
            std::path::Path::new(&ssh_key_path),
        )?;

        // Run post-launch hooks
        let desc_hooks = target::resolve_descriptor_cached(&state.target, false)
            .map(|c| c.descriptor().hooks.post_launch_scripts())
            .unwrap_or_default();

        let hook_scripts = hooks::discover(instance, &desc_hooks, "post-launch")?;
        if !hook_scripts.is_empty() {
            let env = hooks::HookEnv {
                instance_name: instance.to_string(),
                ssh_port,
                ssh_key_path,
                ssh_user: ssh::user(),
                state_dir: instance_store::state_dir().to_string_lossy().to_string(),
            };
            hooks::execute(&env, &hook_scripts)?;
        }
    }

    Ok(())
}
