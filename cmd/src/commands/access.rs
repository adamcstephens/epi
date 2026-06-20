use anyhow::{Result, bail};
use std::io::IsTerminal;
use std::os::unix::process::CommandExt;

use super::lifecycle;
use epi::{backend, console, cp, instance_store, ssh, ui};

/// Ensure the instance is running. If it exists but is stopped, start it —
/// either because `start` was passed, or after an interactive confirmation.
fn ensure_running(instance: &str, start: bool) -> Result<()> {
    if backend::instance_is_running(instance)? {
        return Ok(());
    }

    if instance_store::find(instance)?.is_none() {
        bail!("instance {instance} not found");
    }

    // Exists but stopped.
    if !start {
        if !std::io::stdin().is_terminal() {
            bail!("instance {instance} is stopped — run 'epi start {instance}' or pass --start");
        }
        if !ui::confirm(&format!("Instance {instance} is stopped. Start it?"), true)? {
            bail!("instance {instance} is stopped");
        }
    }

    lifecycle::cmd_start(instance, false, false, 120)?;
    Ok(())
}

pub fn cmd_console(instance: &str) -> Result<()> {
    let capture_path = std::env::var("EPI_CONSOLE_CAPTURE_FILE").ok();
    let timeout = std::env::var("EPI_CONSOLE_TIMEOUT_SECONDS")
        .ok()
        .and_then(|v| v.parse::<f64>().ok());

    console::attach(instance, capture_path.as_deref(), timeout)
}

pub fn cmd_console_log(instance: &str) -> Result<()> {
    console::show_log(instance)
}

pub fn cmd_ssh(instance: &str, start: bool) -> Result<()> {
    ensure_running(instance, start)?;

    let config = ssh::config_path(instance);
    let config_str = config.to_string_lossy();

    let mut args = vec!["-F", &config_str, instance];

    let state = instance_store::load_state(instance)?
        .ok_or_else(|| anyhow::anyhow!("no state for instance {instance}"))?;

    let remote_cmd_opt;
    if let Some(ref dir) = state.project_dir {
        remote_cmd_opt = format!("RemoteCommand=epi-ssh-entry {dir}");
        args.extend(["-o", "RequestTTY=force", "-o", &remote_cmd_opt]);
    }

    let err = std::process::Command::new(ssh::SSH_PROGRAM)
        .args(&args)
        .exec();

    bail!("failed to exec ssh: {err}");
}

pub fn cmd_exec(instance: &str, command: &[String], start: bool) -> Result<()> {
    if command.is_empty() {
        bail!("no command specified");
    }

    ensure_running(instance, start)?;

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

    let err = std::process::Command::new(ssh::SSH_PROGRAM)
        .args(&arg_refs)
        .exec();

    bail!("failed to exec ssh: {err}");
}

pub fn cmd_cp(source: &str, dest: &str, start: bool) -> Result<()> {
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

    ensure_running(instance, start)?;

    let config = ssh::config_path(instance);
    // rsync itself doesn't touch the network; its ssh transport does, so this
    // must be the entitled system ssh on macOS (see ssh::SSH_PROGRAM).
    let ssh_cmd = format!("{} -F {}", ssh::SSH_PROGRAM, config.display());

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
        .args([
            "-a",
            "--info=name1",
            "-e",
            &ssh_cmd,
            &rsync_src,
            &rsync_dest,
        ])
        .exec();

    bail!("failed to exec rsync: {err}");
}
