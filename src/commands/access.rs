use anyhow::{Result, bail};
use std::os::unix::process::CommandExt;

use epi::{console, cp, instance_store, ssh};

fn ensure_running(instance: &str) -> Result<()> {
    instance_store::find_runtime(instance)?
        .ok_or_else(|| anyhow::anyhow!("instance {instance} is not running"))?;
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

pub fn cmd_ssh(instance: &str) -> Result<()> {
    ensure_running(instance)?;

    let config = ssh::config_path(instance);
    let err = std::process::Command::new("ssh")
        .args(["-F", &config.to_string_lossy(), instance])
        .exec();

    bail!("failed to exec ssh: {err}");
}

pub fn cmd_exec(instance: &str, command: &[String]) -> Result<()> {
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

pub fn cmd_cp(source: &str, dest: &str) -> Result<()> {
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
