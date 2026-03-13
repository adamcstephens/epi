use anyhow::Result;
use serde::Deserialize;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Default, Deserialize)]
pub struct Config {
    pub target: Option<String>,
    pub mounts: Option<Vec<String>>,
    pub disk_size: Option<String>,
}

#[derive(Debug, Clone)]
pub struct Resolved {
    pub target: String,
    pub mounts: Vec<String>,
    pub disk_size: String,
}

fn resolve_path(path: &str, base: &Path) -> PathBuf {
    if path.starts_with("~/") {
        if let Ok(home) = std::env::var("HOME") {
            return PathBuf::from(home).join(&path[2..]);
        }
    }
    if path == "~" {
        if let Ok(home) = std::env::var("HOME") {
            return PathBuf::from(home);
        }
    }
    let p = Path::new(path);
    if p.is_absolute() {
        p.to_path_buf()
    } else {
        base.join(path)
    }
}

fn load_from(path: &Path, base_override: Option<&Path>) -> Result<Option<Config>> {
    if !path.exists() {
        return Ok(None);
    }
    let content = fs::read_to_string(path)?;
    let mut config: Config = toml::from_str(&content)?;

    let base = base_override.unwrap_or_else(|| path.parent().unwrap_or(Path::new(".")));

    // Resolve mount paths relative to base directory
    if let Some(ref mut mounts) = config.mounts {
        *mounts = mounts
            .iter()
            .map(|m| resolve_path(m, base).to_string_lossy().to_string())
            .collect();
    }

    Ok(Some(config))
}

pub fn load_project() -> Result<Option<Config>> {
    load_from(Path::new(".epi/config.toml"), Some(Path::new(".")))
}

pub fn load_user() -> Result<Option<Config>> {
    let (path, explicit) = if let Ok(p) = std::env::var("EPI_CONFIG_FILE") {
        (PathBuf::from(p), true)
    } else if let Ok(xdg) = std::env::var("XDG_CONFIG_HOME") {
        (PathBuf::from(xdg).join("epi/config.toml"), false)
    } else if let Ok(home) = std::env::var("HOME") {
        (PathBuf::from(home).join(".config/epi/config.toml"), false)
    } else {
        return Ok(None);
    };
    if explicit && !path.exists() {
        anyhow::bail!("config file not found: {}", path.display());
    }
    load_from(&path, None)
}

fn merge_configs(user: Option<Config>, project: Option<Config>) -> Config {
    let user = user.unwrap_or_default();
    let project = project.unwrap_or_default();
    Config {
        target: project.target.or(user.target),
        mounts: project.mounts.or(user.mounts),
        disk_size: project.disk_size.or(user.disk_size),
    }
}

/// Merge CLI args with config files. CLI args take precedence.
pub fn resolve(
    cli_target: Option<&str>,
    cli_mounts: &[String],
    cli_disk_size: Option<&str>,
) -> Result<Resolved> {
    let user = load_user()?;
    let project = load_project()?;
    let config = merge_configs(user, project);

    let target = cli_target
        .map(|s| s.to_string())
        .or(config.target)
        .ok_or_else(|| {
            anyhow::anyhow!("no target specified (use --target or set in .epi/config.toml)")
        })?;

    let mounts = if cli_mounts.is_empty() {
        config.mounts.unwrap_or_default()
    } else {
        cli_mounts.to_vec()
    };

    let disk_size = cli_disk_size
        .map(|s| s.to_string())
        .or(config.disk_size)
        .unwrap_or_else(|| "40G".to_string());

    Ok(Resolved {
        target,
        mounts,
        disk_size,
    })
}

/// Parse a config from a TOML string with a base path for relative mount resolution.
/// Exposed for testing.
pub fn parse(content: &str, base: &Path) -> Result<Config> {
    let mut config: Config = toml::from_str(content)?;
    if let Some(ref mut mounts) = config.mounts {
        *mounts = mounts
            .iter()
            .map(|m| resolve_path(m, base).to_string_lossy().to_string())
            .collect();
    }
    Ok(config)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_full_config() {
        let toml = r#"
target = ".#dev"
mounts = ["/home/user/project"]
disk_size = "50G"
"#;
        let config = parse(toml, Path::new("/")).unwrap();
        assert_eq!(config.target.unwrap(), ".#dev");
        assert_eq!(config.mounts.unwrap(), vec!["/home/user/project"]);
        assert_eq!(config.disk_size.unwrap(), "50G");
    }

    #[test]
    fn parse_minimal_config() {
        let toml = r#"target = ".#dev""#;
        let config = parse(toml, Path::new("/")).unwrap();
        assert_eq!(config.target.unwrap(), ".#dev");
        assert!(config.mounts.is_none());
        assert!(config.disk_size.is_none());
    }

    #[test]
    fn parse_empty_config() {
        let config = parse("", Path::new("/")).unwrap();
        assert!(config.target.is_none());
    }

    #[test]
    fn resolve_path_absolute() {
        let result = resolve_path("/abs/path", Path::new("/base"));
        assert_eq!(result, PathBuf::from("/abs/path"));
    }

    #[test]
    fn resolve_path_relative() {
        let result = resolve_path("rel/path", Path::new("/base/dir"));
        assert_eq!(result, PathBuf::from("/base/dir/rel/path"));
    }

    #[test]
    fn resolve_path_tilde() {
        let home = std::env::var("HOME").unwrap();
        let result = resolve_path("~/docs", Path::new("/base"));
        assert_eq!(result, PathBuf::from(format!("{home}/docs")));
    }

    #[test]
    fn merge_project_overrides_user() {
        let user = Config {
            target: Some(".#user".into()),
            mounts: Some(vec!["/user/mount".into()]),
            disk_size: Some("30G".into()),
        };
        let project = Config {
            target: Some(".#project".into()),
            mounts: None,
            disk_size: None,
        };
        let merged = merge_configs(Some(user), Some(project));
        assert_eq!(merged.target.unwrap(), ".#project");
        // mounts falls through to user
        assert_eq!(merged.mounts.unwrap(), vec!["/user/mount"]);
        assert_eq!(merged.disk_size.unwrap(), "30G");
    }

    #[test]
    fn merge_user_only() {
        let user = Config {
            target: Some(".#user".into()),
            mounts: None,
            disk_size: None,
        };
        let merged = merge_configs(Some(user), None);
        assert_eq!(merged.target.unwrap(), ".#user");
    }

    #[test]
    fn merge_neither() {
        let merged = merge_configs(None, None);
        assert!(merged.target.is_none());
    }

    #[test]
    fn resolve_cli_overrides_config() {
        // Can't easily test resolve() without mocking file system,
        // but we can test the merging logic via merge_configs
        let config = merge_configs(
            Some(Config {
                target: Some(".#fromconfig".into()),
                mounts: Some(vec!["/config/mount".into()]),
                disk_size: Some("30G".into()),
            }),
            None,
        );

        // CLI target overrides
        let target = Some(".#fromcli").map(|s| s.to_string()).or(config.target);
        assert_eq!(target.unwrap(), ".#fromcli");

        // CLI mounts override when non-empty
        let cli_mounts = vec!["/cli/mount".to_string()];
        let mounts = if cli_mounts.is_empty() {
            config.mounts.unwrap_or_default()
        } else {
            cli_mounts.clone()
        };
        assert_eq!(mounts, vec!["/cli/mount"]);
    }
}
