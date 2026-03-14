use anyhow::{Result, bail};
use clap::{Parser, Subcommand};
use std::os::unix::process::CommandExt;

use epi::{config, console, cp, hooks, instance_store, ssh, target, ui, vm_launch};

fn resolve_instance_name(instance: Option<String>) -> Result<String> {
    match instance {
        Some(name) => Ok(name),
        None => config::resolve_default_name(),
    }
}

/// Manage development VM instances from Nix flake targets.
#[derive(Parser)]
#[command(name = "epi", version)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Create or start an instance from a flake target.
    Launch {
        /// Instance name
        instance: Option<String>,

        /// Flake target in <flake-ref>#<config-name> form
        #[arg(long)]
        target: Option<String>,

        /// Attach to serial console immediately after launch
        #[arg(long)]
        console: bool,

        /// Force re-evaluation and rebuild of target
        #[arg(long)]
        rebuild: bool,

        /// Mount a host directory into the guest (repeatable)
        #[arg(long)]
        mount: Vec<String>,

        /// Target size of writable disk overlay (e.g. 40G)
        #[arg(long)]
        disk_size: Option<String>,

        /// Number of boot CPUs (overrides target descriptor)
        #[arg(long)]
        cpus: Option<u32>,

        /// Memory size in MiB (overrides target descriptor)
        #[arg(long)]
        memory: Option<u32>,

        /// Return immediately without waiting for SSH
        #[arg(long)]
        no_wait: bool,

        /// Max seconds to wait for SSH
        #[arg(long, default_value_t = 120)]
        wait_timeout: u64,
    },

    /// Start an existing stopped instance.
    Start {
        /// Instance name
        instance: Option<String>,

        /// Attach to serial console immediately after starting
        #[arg(long)]
        console: bool,

        /// Return immediately without waiting for SSH
        #[arg(long)]
        no_wait: bool,

        /// Max seconds to wait for SSH
        #[arg(long, default_value_t = 120)]
        wait_timeout: u64,
    },

    /// Stop an instance.
    Stop {
        /// Instance name
        instance: Option<String>,
    },

    /// Show instance status.
    Status {
        /// Instance name
        instance: Option<String>,
    },

    /// Remove an instance from state and runtime.
    Rm {
        /// Instance name
        instance: Option<String>,

        /// Terminate running instance before removing
        #[arg(short, long)]
        force: bool,
    },

    /// List known instances and their targets.
    #[command(alias = "ls")]
    List,

    /// Attach to an instance serial console.
    Console {
        /// Instance name
        instance: Option<String>,
    },

    /// Show captured console log for an instance.
    ConsoleLog {
        /// Instance name
        instance: Option<String>,
    },

    /// Open SSH session to an instance.
    Ssh {
        /// Instance name
        instance: Option<String>,
    },

    /// Execute a command in an instance.
    Exec {
        /// Instance name
        instance: Option<String>,

        /// Command and arguments to execute
        #[arg(last = true)]
        command: Vec<String>,
    },

    /// Rebuild an instance.
    Rebuild {
        /// Instance name
        instance: Option<String>,
    },

    /// Copy files between host and instance.
    Cp {
        /// Source path (local or <instance>:<path>)
        source: String,

        /// Destination path (local or <instance>:<path>)
        dest: String,
    },

    /// Show instance logs.
    Logs {
        /// Instance name
        instance: Option<String>,
    },

    /// Show SSH config for an instance.
    SshConfig {
        /// Instance name
        instance: Option<String>,

        /// Print the config file contents instead of the path
        #[arg(long)]
        print: bool,
    },
}

fn main() {
    let cli = Cli::parse();

    let result = run(cli.command);

    if let Err(e) = result {
        ui::error(&e);
        std::process::exit(123);
    }
}

fn run(command: Command) -> Result<()> {
    match command {
        Command::Launch {
            instance,
            target,
            console,
            rebuild,
            mount,
            disk_size,
            cpus,
            memory,
            no_wait,
            wait_timeout,
        } => {
            let instance = resolve_instance_name(instance)?;
            let mut resolved = config::resolve(
                target.as_deref(),
                &mount,
                disk_size.as_deref(),
                cpus,
                memory,
            )?;
            resolved.target = target::expand_tilde(&resolved.target);
            target::validate(&resolved.target)?;
            cmd_launch(
                &instance,
                &resolved,
                console,
                rebuild,
                no_wait,
                wait_timeout,
            )
        }
        Command::Start {
            instance,
            console,
            no_wait,
            wait_timeout,
        } => {
            let instance = resolve_instance_name(instance)?;
            cmd_start(&instance, console, no_wait, wait_timeout)
        }
        Command::Stop { instance } => cmd_stop(&resolve_instance_name(instance)?),
        Command::Status { instance } => cmd_status(&resolve_instance_name(instance)?),
        Command::Rm { instance, force } => cmd_rm(&resolve_instance_name(instance)?, force),
        Command::List => cmd_list(),
        Command::Console { instance } => cmd_console(&resolve_instance_name(instance)?),
        Command::ConsoleLog { instance } => cmd_console_log(&resolve_instance_name(instance)?),
        Command::Ssh { instance } => cmd_ssh(&resolve_instance_name(instance)?),
        Command::Exec { instance, command } => {
            cmd_exec(&resolve_instance_name(instance)?, &command)
        }
        Command::Cp { source, dest } => cmd_cp(&source, &dest),
        Command::Rebuild { instance } => cmd_rebuild(&resolve_instance_name(instance)?),
        Command::Logs { instance } => cmd_logs(&resolve_instance_name(instance)?),
        Command::SshConfig { instance, print } => {
            cmd_ssh_config(&resolve_instance_name(instance)?, print)
        }
    }
}

fn cmd_launch(
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
        return cmd_status(instance);
    }

    // If instance exists but stale, stop it first
    if instance_store::find_runtime(instance)?.is_some() {
        ui::info(&format!(
            "instance {instance} has stale runtime, cleaning up"
        ));
        let _ = vm_launch::stop_instance(instance);
    }

    let pre_existing = instance_store::find(instance)?.is_some();
    instance_store::set_launching(instance, &resolved.target, resolved.mounts.clone())?;

    let step = ui::Step::start(&format!("Provisioning {instance}"));

    let runtime = match vm_launch::provision(
        instance,
        &resolved.target,
        &resolved.mounts,
        &resolved.disk_size,
        rebuild,
        resolved.cpus,
        resolved.memory,
    ) {
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

    // Start console capture in background
    console::start_capture(instance)?;

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

fn cmd_start(instance: &str, attach_console: bool, no_wait: bool, wait_timeout: u64) -> Result<()> {
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
    let runtime = vm_launch::provision(instance, &state.target, &mounts, "40G", false, None, None)?;
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

    console::start_capture(instance)?;

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

fn cmd_stop(instance: &str) -> Result<()> {
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

fn cmd_status(instance: &str) -> Result<()> {
    let state = instance_store::load_state(instance)?
        .ok_or_else(|| anyhow::anyhow!("instance {instance} not found"))?;

    let running = instance_store::instance_is_running(instance)?;

    println!("instance:  {}", ui::bold(instance));
    println!("target:    {}", state.target);
    println!("status:    {}", ui::status_dot(running));

    if let Some(ref rt) = state.runtime {
        if let Some(port) = rt.ssh_port {
            println!("ssh port:  {port}");
        }
        println!("serial:    {}", rt.serial_socket);
        println!("disk:      {}", rt.disk);
        println!("unit id:   {}", rt.unit_id);
    }

    Ok(())
}

fn cmd_rm(instance: &str, force: bool) -> Result<()> {
    let running = instance_store::instance_is_running(instance)?;

    if running && !force {
        bail!("instance {instance} is running — use --force to terminate and remove");
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

fn cmd_list() -> Result<()> {
    let instances = instance_store::list()?;

    if instances.is_empty() {
        println!("no instances");
        return Ok(());
    }

    println!("{:<16} {:<40} {:<14} SSH", "INSTANCE", "TARGET", "STATUS");

    for (name, target_str) in &instances {
        let running = instance_store::instance_is_running(name)?;
        let status = ui::status_dot(running);
        let ssh = if running {
            instance_store::find_runtime(name)?
                .and_then(|rt| rt.ssh_port)
                .map(|p| format!("127.0.0.1:{p}"))
                .unwrap_or_else(|| "\u{2014}".to_string())
        } else {
            "\u{2014}".to_string()
        };

        println!("{:<16} {:<40} {:<14} {}", name, target_str, status, ssh);
    }

    Ok(())
}

fn cmd_console(instance: &str) -> Result<()> {
    let capture_path = std::env::var("EPI_CONSOLE_CAPTURE_FILE").ok();
    let timeout = std::env::var("EPI_CONSOLE_TIMEOUT_SECONDS")
        .ok()
        .and_then(|v| v.parse::<f64>().ok());

    console::attach(instance, capture_path.as_deref(), timeout)
}

fn cmd_console_log(instance: &str) -> Result<()> {
    console::show_log(instance)
}

fn ensure_running(instance: &str) -> Result<()> {
    instance_store::find_runtime(instance)?
        .ok_or_else(|| anyhow::anyhow!("instance {instance} is not running"))?;
    Ok(())
}

fn cmd_ssh(instance: &str) -> Result<()> {
    ensure_running(instance)?;

    let config = ssh::config_path(instance);
    let err = std::process::Command::new("ssh")
        .args(["-F", &config.to_string_lossy(), instance])
        .exec();

    bail!("failed to exec ssh: {err}");
}

fn cmd_exec(instance: &str, command: &[String]) -> Result<()> {
    if command.is_empty() {
        bail!("no command specified");
    }

    ensure_running(instance)?;

    let config = ssh::config_path(instance);
    let config_str = config.to_string_lossy();

    let mut args = vec![
        "-F".to_string(),
        config_str.to_string(),
        instance.to_string(),
        "--".to_string(),
    ];
    args.extend_from_slice(command);

    let arg_refs: Vec<&str> = args.iter().map(|s| s.as_str()).collect();

    let err = std::process::Command::new("ssh").args(&arg_refs).exec();

    bail!("failed to exec ssh: {err}");
}

fn cmd_cp(source: &str, dest: &str) -> Result<()> {
    let spec = cp::parse_copy_spec(source, dest)?;

    let (instance, remote_path, is_push) = match (&spec.source, &spec.dest) {
        (cp::Endpoint::Local(_), cp::Endpoint::Remote { instance, path }) => {
            (instance.as_str(), path.as_str(), true)
        }
        (cp::Endpoint::Remote { instance, path }, cp::Endpoint::Local(_)) => {
            (instance.as_str(), path.as_str(), false)
        }
        _ => unreachable!("parse_copy_spec validates exactly one side is remote"),
    };

    ensure_running(instance)?;

    let config = ssh::config_path(instance);
    let ssh_cmd = format!("ssh -F {}", config.display());

    let remote = format!("{instance}:{remote_path}");

    let (rsync_src, rsync_dest) = if is_push {
        let local_path = match &spec.source {
            cp::Endpoint::Local(p) => p.as_str(),
            _ => unreachable!(),
        };
        (local_path.to_string(), remote)
    } else {
        let local_path = match &spec.dest {
            cp::Endpoint::Local(p) => p.as_str(),
            _ => unreachable!(),
        };
        (remote, local_path.to_string())
    };

    let err = std::process::Command::new("rsync")
        .args(["-a", "--progress", "-e", &ssh_cmd, &rsync_src, &rsync_dest])
        .exec();

    bail!("failed to exec rsync: {err}");
}

fn cmd_rebuild(instance: &str) -> Result<()> {
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
    let runtime = vm_launch::provision(instance, &state.target, &mounts, "40G", true, None, None)?;
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

    console::start_capture(instance)?;

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

fn cmd_logs(instance: &str) -> Result<()> {
    let runtime = instance_store::find_runtime(instance)?
        .ok_or_else(|| anyhow::anyhow!("instance {instance} not found or not running"))?;

    let slice = instance_store::slice_name(instance, &runtime.unit_id)?;
    let err = std::process::Command::new("journalctl")
        .args(["--user", "--unit", &slice, "--follow"])
        .exec();

    bail!("failed to exec journalctl: {err}")
}

fn cmd_ssh_config(instance: &str, print: bool) -> Result<()> {
    ensure_running(instance)?;

    let config = ssh::config_path(instance);
    if !config.exists() {
        bail!(
            "SSH config not found for instance {instance} — it may have launched before config generation was added"
        );
    }

    if print {
        let contents = std::fs::read_to_string(&config)?;
        print!("{contents}");
    } else {
        println!("{}", config.display());
    }

    Ok(())
}
