use anyhow::Result;
use clap::{CommandFactory, Parser, Subcommand};
use clap_complete::Shell;
use clap_complete::engine::{ArgValueCompleter, CompletionCandidate};

use epi::{config, instance_store, target, ui};

mod commands;

fn complete_instance(current: &std::ffi::OsStr) -> Vec<CompletionCandidate> {
    let current = current.to_string_lossy();
    instance_store::list()
        .unwrap_or_default()
        .into_iter()
        .filter(|(name, _, _)| name.starts_with(current.as_ref()))
        .map(|(name, target, _)| CompletionCandidate::new(name).help(Some(target.into())))
        .collect()
}

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
        #[arg(add = ArgValueCompleter::new(complete_instance))]
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

        /// Map a TCP port from host to guest (repeatable, e.g. 8080:80 or :443)
        #[arg(long)]
        port: Vec<String>,

        /// Do not auto-mount project directory into the guest
        #[arg(long)]
        no_project_mount: bool,

        /// Skip post-launch provisioning (SSH wait, host key trust, hooks)
        #[arg(long)]
        no_provision: bool,

        /// Max seconds to wait for SSH
        #[arg(long, default_value_t = 120)]
        wait_timeout: u64,
    },

    /// Start an existing stopped instance.
    Start {
        /// Instance name
        #[arg(add = ArgValueCompleter::new(complete_instance))]
        instance: Option<String>,

        /// Attach to serial console immediately after starting
        #[arg(long)]
        console: bool,

        /// Skip post-launch provisioning (SSH wait, host key trust, hooks)
        #[arg(long)]
        no_provision: bool,

        /// Max seconds to wait for SSH
        #[arg(long, default_value_t = 120)]
        wait_timeout: u64,
    },

    /// Stop an instance.
    Stop {
        /// Instance name
        #[arg(add = ArgValueCompleter::new(complete_instance))]
        instance: Option<String>,
    },

    /// Show detailed instance information.
    Info {
        /// Instance name
        #[arg(add = ArgValueCompleter::new(complete_instance))]
        instance: Option<String>,
    },

    /// Remove an instance from state and runtime.
    Rm {
        /// Instance name
        #[arg(add = ArgValueCompleter::new(complete_instance))]
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
        #[arg(add = ArgValueCompleter::new(complete_instance))]
        instance: Option<String>,
    },

    /// Show captured console log for an instance.
    ConsoleLog {
        /// Instance name
        #[arg(add = ArgValueCompleter::new(complete_instance))]
        instance: Option<String>,
    },

    /// Open SSH session to an instance.
    Ssh {
        /// Instance name
        #[arg(add = ArgValueCompleter::new(complete_instance))]
        instance: Option<String>,
    },

    /// Execute a command in an instance.
    Exec {
        /// Instance name
        #[arg(add = ArgValueCompleter::new(complete_instance))]
        instance: Option<String>,

        /// Command and arguments to execute
        #[arg(last = true)]
        command: Vec<String>,
    },

    /// Rebuild an instance.
    Rebuild {
        /// Instance name
        #[arg(add = ArgValueCompleter::new(complete_instance))]
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
        #[arg(add = ArgValueCompleter::new(complete_instance))]
        instance: Option<String>,
    },

    /// Show SSH config for an instance.
    SshConfig {
        /// Instance name
        #[arg(add = ArgValueCompleter::new(complete_instance))]
        instance: Option<String>,

        /// Print the config file contents instead of the path
        #[arg(long)]
        print: bool,
    },

    /// Initialize a new epi project in the current directory.
    Init {
        /// Flake target in <flake-ref>#<config-name> form
        #[arg(long)]
        target: Option<String>,

        /// Skip interactive prompts, use defaults
        #[arg(long, short = 'n')]
        no_confirm: bool,
    },

    /// Generate shell completion scripts.
    Completions {
        /// Shell to generate completions for
        shell: Shell,
    },
}

fn main() {
    clap_complete::CompleteEnv::with_factory(Cli::command).complete();

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
            port,
            no_project_mount,
            no_provision,
            wait_timeout,
        } => {
            let instance = resolve_instance_name(instance)?;
            let mut resolved = config::resolve(
                target.as_deref(),
                &mount,
                disk_size.as_deref(),
                cpus,
                memory,
                &port,
                no_project_mount,
            )?;
            resolved.target = target::expand_tilde(&resolved.target);
            target::validate(&resolved.target)?;
            commands::cmd_launch(
                &instance,
                &resolved,
                console,
                rebuild,
                no_provision,
                wait_timeout,
            )
        }
        Command::Start {
            instance,
            console,
            no_provision,
            wait_timeout,
        } => {
            let instance = resolve_instance_name(instance)?;
            commands::cmd_start(&instance, console, no_provision, wait_timeout)
        }
        Command::Stop { instance } => commands::cmd_stop(&resolve_instance_name(instance)?),
        Command::Info { instance } => commands::cmd_info(&resolve_instance_name(instance)?),
        Command::Rm { instance, force } => {
            commands::cmd_rm(&resolve_instance_name(instance)?, force)
        }
        Command::List => commands::cmd_list(),
        Command::Console { instance } => commands::cmd_console(&resolve_instance_name(instance)?),
        Command::ConsoleLog { instance } => {
            commands::cmd_console_log(&resolve_instance_name(instance)?)
        }
        Command::Ssh { instance } => commands::cmd_ssh(&resolve_instance_name(instance)?),
        Command::Exec { instance, command } => {
            commands::cmd_exec(&resolve_instance_name(instance)?, &command)
        }
        Command::Cp { source, dest } => commands::cmd_cp(&source, &dest),
        Command::Rebuild { instance } => commands::cmd_rebuild(&resolve_instance_name(instance)?),
        Command::Logs { instance } => commands::cmd_logs(&resolve_instance_name(instance)?),
        Command::SshConfig { instance, print } => {
            commands::cmd_ssh_config(&resolve_instance_name(instance)?, print)
        }
        Command::Init { target, no_confirm } => commands::cmd_init(target, no_confirm),
        Command::Completions { shell } => {
            let mut cmd = Cli::command();
            clap_complete::generate(shell, &mut cmd, "epi", &mut std::io::stdout());
            Ok(())
        }
    }
}
