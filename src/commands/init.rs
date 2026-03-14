use anyhow::{Result, bail};
use std::path::Path;

use epi::{config, ui};

fn prompt(label: &str, default: Option<&str>) -> Result<String> {
    if let Some(def) = default {
        eprint!("{label} [{def}]: ");
    } else {
        eprint!("{label}: ");
    }
    let mut input = String::new();
    std::io::stdin().read_line(&mut input)?;
    let input = input.trim().to_string();
    if input.is_empty() {
        if let Some(def) = default {
            return Ok(def.to_string());
        }
        bail!("{label} is required");
    }
    Ok(input)
}

pub fn cmd_init(target: Option<String>, no_confirm: bool) -> Result<()> {
    let config_path = Path::new(".epi/config.toml");
    if config_path.exists() {
        bail!("project already initialized (.epi/config.toml exists)");
    }

    let dir_basename = std::env::current_dir()?
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "default".to_string());

    let (target, default_name, cpus, memory) = if no_confirm {
        let target = target
            .ok_or_else(|| anyhow::anyhow!("--target is required when using --no-confirm"))?;
        (target, dir_basename, None, None)
    } else {
        let target_default = target.as_deref();
        let target = prompt("target", target_default)?;

        let default_name = prompt("default_name", Some(&dir_basename))?;

        let cpus_str = prompt("cpus", Some("2"))?;
        let cpus: u32 = cpus_str
            .parse()
            .map_err(|_| anyhow::anyhow!("cpus must be a number"))?;

        let memory_str = prompt("memory", Some("2048"))?;
        let memory: u32 = memory_str
            .parse()
            .map_err(|_| anyhow::anyhow!("memory must be a number"))?;

        (target, default_name, Some(cpus), Some(memory))
    };

    let init_config = config::Config {
        target: Some(target),
        default_name: Some(default_name),
        cpus,
        memory,
        ..config::Config::default()
    };

    let toml_content = config::generate_toml(&init_config);

    std::fs::create_dir_all(".epi")?;
    std::fs::write(config_path, &toml_content)?;

    ui::info("initialized epi project in .epi/config.toml");

    Ok(())
}
