use anyhow::{Result, bail};
use std::os::unix::process::CommandExt;

use epi::{instance_store, ssh, ui};

pub fn cmd_info(instance: &str) -> Result<()> {
    let state = instance_store::load_state(instance)?
        .ok_or_else(|| anyhow::anyhow!("instance {instance} not found"))?;

    let running = instance_store::instance_is_running(instance)?;

    // Identity
    println!("instance:   {}", ui::bold(instance));
    println!("target:     {}", state.target);
    if let Some(ref project) = state.project_dir {
        println!("project:    {}", strip_home(project));
    }
    println!("status:     {}", ui::status_dot(running));

    // Resources
    if let Some(ref disk_size) = state.disk_size {
        println!();
        println!("resources:");
        println!("  disk:     {disk_size}");
    }

    // Network
    if let Some(ref rt) = state.runtime {
        let has_ssh = rt.ssh_port.is_some();
        let has_ports = !rt.ports.is_empty();
        if has_ssh || has_ports {
            println!();
            println!("network:");
            if let Some(port) = rt.ssh_port {
                println!("  ssh:      ssh -p {port} root@127.0.0.1");
            }
            if has_ports {
                for (i, pm) in rt.ports.iter().enumerate() {
                    if i == 0 {
                        println!("  ports:    {}:{} ({})", pm.host, pm.guest, pm.protocol);
                    } else {
                        println!("            {}:{} ({})", pm.host, pm.guest, pm.protocol);
                    }
                }
            }
        }
    }

    // Mounts
    if !state.mounts.is_empty() {
        println!();
        println!("mounts:");
        for mount in &state.mounts {
            println!("  {}", strip_home(mount));
        }
    }

    // Runtime
    if let Some(ref rt) = state.runtime {
        println!();
        println!("runtime:");
        println!("  serial:   {}", rt.serial_socket);
        println!("  disk:     {}", rt.disk);
        println!("  unit id:  {}", rt.unit_id);
    }

    Ok(())
}

fn strip_home(path: &str) -> String {
    if let Ok(home) = std::env::var("HOME")
        && let Some(rest) = path.strip_prefix(&home)
    {
        return format!("~{rest}");
    }
    path.to_string()
}

pub fn cmd_list() -> Result<()> {
    let instances = instance_store::list()?;

    if instances.is_empty() {
        println!("no instances");
        return Ok(());
    }

    let has_projects = instances.iter().any(|(_, _, p)| p.is_some());

    if has_projects {
        println!(
            "{:<16} {:<40} {:<14} {:<20} {:<24} PORTS",
            "INSTANCE", "TARGET", "STATUS", "SSH", "PROJECT"
        );
    } else {
        println!(
            "{:<16} {:<40} {:<14} {:<20} PORTS",
            "INSTANCE", "TARGET", "STATUS", "SSH"
        );
    }

    for (name, target_str, project_dir) in &instances {
        let running = instance_store::instance_is_running(name)?;
        let status = ui::status_dot(running);
        let (ssh, ports_str) = if running {
            let rt = instance_store::find_runtime(name)?;
            let ssh = rt
                .as_ref()
                .and_then(|rt| rt.ssh_port)
                .map(|p| format!("127.0.0.1:{p}"))
                .unwrap_or_else(|| "\u{2014}".to_string());
            let ports = rt
                .as_ref()
                .map(|rt| {
                    rt.ports
                        .iter()
                        .map(|pm| format!("{}:{}", pm.host, pm.guest))
                        .collect::<Vec<_>>()
                        .join(", ")
                })
                .unwrap_or_default();
            (ssh, ports)
        } else {
            ("\u{2014}".to_string(), String::new())
        };

        if has_projects {
            let project = project_dir
                .as_deref()
                .map(strip_home)
                .unwrap_or_else(|| "\u{2014}".to_string());
            println!(
                "{:<16} {:<40} {:<14} {:<20} {:<24} {}",
                name, target_str, status, ssh, project, ports_str
            );
        } else {
            println!(
                "{:<16} {:<40} {:<14} {:<20} {}",
                name, target_str, status, ssh, ports_str
            );
        }
    }

    Ok(())
}

pub fn cmd_logs(instance: &str) -> Result<()> {
    let runtime = instance_store::find_runtime(instance)?
        .ok_or_else(|| anyhow::anyhow!("instance {instance} not found or not running"))?;

    let slice = instance_store::slice_name(instance, &runtime.unit_id)?;
    let err = std::process::Command::new("journalctl")
        .args(["--user", "--unit", &slice, "--follow"])
        .exec();

    bail!("failed to exec journalctl: {err}")
}

pub fn cmd_ssh_config(instance: &str, print: bool) -> Result<()> {
    fn ensure_running(instance: &str) -> Result<()> {
        instance_store::find_runtime(instance)?
            .ok_or_else(|| anyhow::anyhow!("instance {instance} is not running"))?;
        Ok(())
    }

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
