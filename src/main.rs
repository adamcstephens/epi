use anyhow::{Result, bail};
use clap::{Parser, Subcommand};
use std::os::unix::process::CommandExt;

use epi::{config, console, hooks, instance_store, process, target, vm_launch};

fn ssh_user() -> String {
    std::env::var("USER").unwrap_or_else(|_| "user".to_string())
}

fn ssh_target() -> String {
    format!("{}@127.0.0.1", ssh_user())
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
        #[arg(default_value = "default")]
        instance: String,

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
        #[arg(default_value = "default")]
        instance: String,

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
        #[arg(default_value = "default")]
        instance: String,
    },

    /// Show instance status.
    Status {
        /// Instance name
        #[arg(default_value = "default")]
        instance: String,
    },

    /// Remove an instance from state and runtime.
    Rm {
        /// Instance name
        #[arg(default_value = "default")]
        instance: String,

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
        #[arg(default_value = "default")]
        instance: String,
    },

    /// Show captured console log for an instance.
    ConsoleLog {
        /// Instance name
        #[arg(default_value = "default")]
        instance: String,
    },

    /// Open SSH session to an instance.
    Ssh {
        /// Instance name
        #[arg(default_value = "default")]
        instance: String,
    },

    /// Execute a command in an instance.
    Exec {
        /// Instance name
        #[arg(default_value = "default")]
        instance: String,

        /// Command and arguments to execute
        #[arg(last = true)]
        command: Vec<String>,
    },

    /// Rebuild an instance.
    Rebuild {
        /// Instance name
        #[arg(default_value = "default")]
        instance: String,
    },

    /// Show instance logs.
    Logs {
        /// Instance name
        #[arg(default_value = "default")]
        instance: String,
    },
}

fn main() {
    let cli = Cli::parse();

    let result = match cli.command {
        Command::Launch {
            instance,
            target,
            console,
            rebuild,
            mount,
            disk_size,
            no_wait,
            wait_timeout,
        } => cmd_launch(
            &instance,
            target.as_deref(),
            console,
            rebuild,
            &mount,
            disk_size.as_deref(),
            no_wait,
            wait_timeout,
        ),
        Command::Start {
            instance,
            console,
            no_wait,
            wait_timeout,
        } => cmd_start(&instance, console, no_wait, wait_timeout),
        Command::Stop { instance } => cmd_stop(&instance),
        Command::Status { instance } => cmd_status(&instance),
        Command::Rm { instance, force } => cmd_rm(&instance, force),
        Command::List => cmd_list(),
        Command::Console { instance } => cmd_console(&instance),
        Command::ConsoleLog { instance } => cmd_console_log(&instance),
        Command::Ssh { instance } => cmd_ssh(&instance),
        Command::Exec { instance, command } => cmd_exec(&instance, &command),
        Command::Rebuild { instance } => cmd_rebuild(&instance),
        Command::Logs { instance } => cmd_logs(&instance),
    };

    if let Err(e) = result {
        eprintln!("error: {e:#}");
        std::process::exit(123);
    }
}

fn cmd_launch(
    instance: &str,
    cli_target: Option<&str>,
    attach_console: bool,
    rebuild: bool,
    cli_mounts: &[String],
    cli_disk_size: Option<&str>,
    no_wait: bool,
    wait_timeout: u64,
) -> Result<()> {
    // Check if already running
    if instance_store::instance_is_running(instance)? {
        eprintln!("instance {instance} is already running");
        if attach_console {
            return console::attach(instance, None, None);
        }
        return cmd_status(instance);
    }

    // If instance exists but stale, stop it first
    if instance_store::find_runtime(instance)?.is_some() {
        eprintln!("instance {instance} has stale runtime, cleaning up");
        let _ = vm_launch::stop_instance(instance);
    }

    let mut resolved = config::resolve(cli_target, cli_mounts, cli_disk_size)?;
    resolved.target = target::expand_tilde(&resolved.target);

    target::validate(&resolved.target)?;

    let pre_existing = instance_store::find(instance)?.is_some();
    instance_store::set_launching(instance, &resolved.target, resolved.mounts.clone())?;

    eprintln!("provisioning {instance} from {}", resolved.target);

    let runtime = match vm_launch::provision(
        instance,
        &resolved.target,
        &resolved.mounts,
        &resolved.disk_size,
        rebuild,
    ) {
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

    let ssh_port = runtime.ssh_port.unwrap_or(0);
    let ssh_key_path = runtime.ssh_key_path.clone();

    instance_store::set_provisioned(instance, runtime)?;

    // Start console capture in background
    console::start_capture(instance)?;

    let no_wait = no_wait
        || std::env::var("EPI_NO_WAIT")
            .map(|v| v == "true" || v == "1")
            .unwrap_or(false);

    if attach_console {
        // Run SSH wait + hooks in background so console attaches immediately
        let wait_handle = if !no_wait && ssh_port > 0 {
            let inst = instance.to_string();
            let key = ssh_key_path.clone();
            let tgt = resolved.target.clone();
            let timeout = std::env::var("EPI_WAIT_TIMEOUT_SECONDS")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(wait_timeout);
            Some(std::thread::spawn(move || -> Result<()> {
                eprintln!("waiting for SSH on port {ssh_port}...");
                vm_launch::wait_for_ssh(ssh_port, &key, timeout)?;
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
    } else if !no_wait && ssh_port > 0 {
        let timeout = std::env::var("EPI_WAIT_TIMEOUT_SECONDS")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(wait_timeout);

        eprintln!("waiting for SSH on port {ssh_port}...");
        vm_launch::wait_for_ssh(ssh_port, &ssh_key_path, timeout)?;
        eprintln!("instance {instance} is ready (ssh port {ssh_port})");

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
        .map(|c| c.descriptor().hooks.post_launch.clone())
        .unwrap_or_default();

    let hook_scripts = hooks::discover(instance, &desc_hooks, "post-launch")?;
    if !hook_scripts.is_empty() {
        let env = hooks::HookEnv {
            instance_name: instance.to_string(),
            ssh_port,
            ssh_key_path: ssh_key_path.to_string(),
            ssh_user: ssh_user(),
            state_dir: instance_store::state_dir().to_string_lossy().to_string(),
        };
        hooks::execute(&env, &hook_scripts)?;
    }
    Ok(())
}

fn cmd_start(instance: &str, attach_console: bool, no_wait: bool, wait_timeout: u64) -> Result<()> {
    if instance_store::instance_is_running(instance)? {
        eprintln!("instance {instance} is already running");
        if attach_console {
            return console::attach(instance, None, None);
        }
        return Ok(());
    }

    let state = instance_store::load_state(instance)?
        .ok_or_else(|| anyhow::anyhow!("instance {instance} not found — use 'launch' first"))?;

    let mounts = state.mounts.clone();

    eprintln!("starting {instance} from {}", state.target);

    let runtime = vm_launch::provision(instance, &state.target, &mounts, "40G", false)?;

    let ssh_port = runtime.ssh_port.unwrap_or(0);
    let ssh_key_path = runtime.ssh_key_path.clone();

    instance_store::set_provisioned(instance, runtime)?;
    console::start_capture(instance)?;

    if !no_wait && ssh_port > 0 {
        eprintln!("waiting for SSH on port {ssh_port}...");
        vm_launch::wait_for_ssh(ssh_port, &ssh_key_path, wait_timeout)?;
        eprintln!("instance {instance} is ready");
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
            eprintln!("stop: instance {instance} was already stopped (stale runtime cleared)");
        } else {
            eprintln!("instance {instance} is not running");
        }
        return Ok(());
    }

    // Run pre-stop hooks
    let state = instance_store::load_state(instance)?;
    if let Some(ref st) = state {
        if let Some(ref rt) = st.runtime {
            if let Some(ssh_port) = rt.ssh_port {
                let desc_hooks = target::resolve_descriptor_cached(&st.target, false)
                    .map(|c| c.descriptor().hooks.pre_stop.clone())
                    .unwrap_or_default();

                let hook_scripts = hooks::discover(instance, &desc_hooks, "pre-stop")?;
                if !hook_scripts.is_empty() {
                    let env = hooks::HookEnv {
                        instance_name: instance.to_string(),
                        ssh_port,
                        ssh_key_path: rt.ssh_key_path.clone(),
                        ssh_user: ssh_user(),
                        state_dir: instance_store::state_dir().to_string_lossy().to_string(),
                    };
                    hooks::execute(&env, &hook_scripts)?;
                }
            }
        }
    }

    eprintln!("stopping {instance}");
    vm_launch::stop_instance(instance)?;
    eprintln!("instance {instance} stopped");
    Ok(())
}

fn cmd_status(instance: &str) -> Result<()> {
    let state = instance_store::load_state(instance)?
        .ok_or_else(|| anyhow::anyhow!("instance {instance} not found"))?;

    let running = instance_store::instance_is_running(instance)?;
    let status = if running { "running" } else { "stopped" };

    println!("instance:  {instance}");
    println!("target:    {}", state.target);
    println!("status:    {status}");

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
        eprintln!("terminating {instance}");
        vm_launch::stop_instance(instance)?;
    }

    instance_store::remove(instance)?;
    eprintln!("removed {instance}");
    Ok(())
}

fn cmd_list() -> Result<()> {
    let instances = instance_store::list()?;

    if instances.is_empty() {
        println!("no instances");
        return Ok(());
    }

    println!(
        "{:<16} {:<40} {:<10} {}",
        "INSTANCE", "TARGET", "STATUS", "SSH"
    );

    for (name, target_str) in &instances {
        let running = instance_store::instance_is_running(name)?;
        let status = if running { "running" } else { "stopped" };
        let ssh = instance_store::find_runtime(name)?
            .and_then(|rt| rt.ssh_port)
            .map(|p| format!("127.0.0.1:{p}"))
            .unwrap_or_default();

        println!("{:<16} {:<40} {:<10} {}", name, target_str, status, ssh);
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

fn cmd_ssh(instance: &str) -> Result<()> {
    let runtime = instance_store::find_runtime(instance)?
        .ok_or_else(|| anyhow::anyhow!("instance {instance} is not running"))?;

    let ssh_port = runtime
        .ssh_port
        .ok_or_else(|| anyhow::anyhow!("no SSH port for instance {instance}"))?;

    let err = std::process::Command::new("ssh")
        .args([
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "UserKnownHostsFile=/dev/null",
            "-o",
            "LogLevel=ERROR",
            "-i",
            &runtime.ssh_key_path,
            "-p",
            &ssh_port.to_string(),
            &ssh_target(),
        ])
        .exec();

    // exec() only returns on error
    bail!("failed to exec ssh: {err}");
}

fn cmd_exec(instance: &str, command: &[String]) -> Result<()> {
    if command.is_empty() {
        bail!("no command specified");
    }

    let runtime = instance_store::find_runtime(instance)?
        .ok_or_else(|| anyhow::anyhow!("instance {instance} is not running"))?;

    let ssh_port = runtime
        .ssh_port
        .ok_or_else(|| anyhow::anyhow!("no SSH port for instance {instance}"))?;

    let mut args = vec![
        "-o".to_string(),
        "StrictHostKeyChecking=no".to_string(),
        "-o".to_string(),
        "UserKnownHostsFile=/dev/null".to_string(),
        "-o".to_string(),
        "LogLevel=ERROR".to_string(),
        "-i".to_string(),
        runtime.ssh_key_path.clone(),
        "-p".to_string(),
        ssh_port.to_string(),
        ssh_target(),
        "--".to_string(),
    ];
    args.extend_from_slice(command);

    let arg_refs: Vec<&str> = args.iter().map(|s| s.as_str()).collect();

    let err = std::process::Command::new("ssh").args(&arg_refs).exec();

    bail!("failed to exec ssh: {err}");
}

fn cmd_rebuild(instance: &str) -> Result<()> {
    let state = instance_store::load_state(instance)?
        .ok_or_else(|| anyhow::anyhow!("instance {instance} not found"))?;

    let was_running = instance_store::instance_is_running(instance)?;
    if was_running {
        eprintln!("stopping {instance} for rebuild");
        vm_launch::stop_instance(instance)?;
    }

    // Remove disk to force fresh overlay
    let disk_path = instance_store::instance_path(instance, "disk.img");
    if disk_path.exists() {
        std::fs::remove_file(&disk_path)?;
    }

    eprintln!("rebuilding {instance} from {}", state.target);
    let mounts = state.mounts.clone();
    let runtime = vm_launch::provision(instance, &state.target, &mounts, "40G", true)?;

    let ssh_port = runtime.ssh_port.unwrap_or(0);
    let ssh_key_path = runtime.ssh_key_path.clone();

    instance_store::set_provisioned(instance, runtime)?;
    console::start_capture(instance)?;

    if ssh_port > 0 {
        eprintln!("waiting for SSH on port {ssh_port}...");
        vm_launch::wait_for_ssh(ssh_port, &ssh_key_path, 120)?;
        eprintln!("instance {instance} rebuilt and ready");

        // Run post-launch hooks
        let desc_hooks = target::resolve_descriptor_cached(&state.target, false)
            .map(|c| c.descriptor().hooks.post_launch.clone())
            .unwrap_or_default();

        let hook_scripts = hooks::discover(instance, &desc_hooks, "post-launch")?;
        if !hook_scripts.is_empty() {
            let env = hooks::HookEnv {
                instance_name: instance.to_string(),
                ssh_port,
                ssh_key_path,
                ssh_user: ssh_user(),
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

    let unit = instance_store::vm_unit_name(instance, &runtime.unit_id)?;
    let out = process::run(
        "journalctl",
        &["--user", "--unit", &unit, "--no-pager", "--output=cat"],
    )?;
    println!("{}", out.stdout);
    Ok(())
}
