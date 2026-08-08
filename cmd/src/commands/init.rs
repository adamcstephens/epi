use anyhow::{Result, bail};
use std::io::BufRead;
use std::path::Path;

use epi::{config, ui};

fn prompt(reader: &mut impl BufRead, label: &str, default: Option<&str>) -> Result<Option<String>> {
    if let Some(def) = default {
        eprint!("{label} [{def}]: ");
    } else {
        eprint!("{label} (optional): ");
    }
    let mut input = String::new();
    reader.read_line(&mut input)?;
    let input = input.trim();
    if input.is_empty() {
        return Ok(default.map(str::to_string));
    }
    Ok(Some(input.to_string()))
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
        (target, Some(dir_basename), None, None)
    } else {
        let stdin = std::io::stdin();
        let mut reader = stdin.lock();

        let target = prompt(&mut reader, "target", target.as_deref())?;
        let default_name = prompt(&mut reader, "default_name", Some(&dir_basename))?;

        let cpus = prompt(&mut reader, "cpus", Some("2"))?
            .map(|s| s.parse())
            .transpose()
            .map_err(|_| anyhow::anyhow!("cpus must be a number"))?;

        let memory = prompt(&mut reader, "memory", Some("2048"))?
            .map(|s| s.parse())
            .transpose()
            .map_err(|_| anyhow::anyhow!("memory must be a number"))?;

        (target, default_name, cpus, memory)
    };

    let init_config = config::Config {
        target,
        default_name,
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn empty_without_default_is_none() {
        let mut input = Cursor::new("\n");
        assert_eq!(prompt(&mut input, "target", None).unwrap(), None);
    }

    #[test]
    fn empty_with_default_uses_default() {
        let mut input = Cursor::new("\n");
        assert_eq!(
            prompt(&mut input, "cpus", Some("2")).unwrap(),
            Some("2".to_string())
        );
    }

    #[test]
    fn input_overrides_default() {
        let mut input = Cursor::new("4\n");
        assert_eq!(
            prompt(&mut input, "cpus", Some("2")).unwrap(),
            Some("4".to_string())
        );
    }

    #[test]
    fn input_is_trimmed() {
        let mut input = Cursor::new("  .#dev  \n");
        assert_eq!(
            prompt(&mut input, "target", None).unwrap(),
            Some(".#dev".to_string())
        );
    }
}
