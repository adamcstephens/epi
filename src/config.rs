use anyhow::Result;
use serde::Deserialize;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Default, Deserialize)]
pub struct Config {
    pub target: Option<String>,
    pub mounts: Option<Vec<String>>,
    pub disk_size: Option<String>,
    pub cpus: Option<u32>,
    pub memory: Option<u32>,
    pub default_name: Option<String>,
    pub ports: Option<Vec<String>>,
    pub project_mount: Option<bool>,
}

#[derive(Debug, Clone)]
pub struct Resolved {
    pub target: String,
    pub mounts: Vec<String>,
    pub disk_size: String,
    pub cpus: Option<u32>,
    pub memory: Option<u32>,
    pub default_name: String,
    pub ports: Vec<String>,
}

fn resolve_path(path: &str, base: &Path) -> PathBuf {
    if let Some(stripped) = path.strip_prefix("~/")
        && let Ok(home) = std::env::var("HOME")
    {
        return PathBuf::from(home).join(stripped);
    }
    if path == "~"
        && let Ok(home) = std::env::var("HOME")
    {
        return PathBuf::from(home);
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

/// Returns the canonicalized project directory if .epi/config.toml exists.
pub fn project_dir() -> Result<Option<String>> {
    if Path::new(".epi/config.toml").exists() {
        let dir = Path::new(".").canonicalize()?;
        Ok(Some(dir.to_string_lossy().to_string()))
    } else {
        Ok(None)
    }
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
        mounts: merge_mount_lists(user.mounts, project.mounts),
        disk_size: project.disk_size.or(user.disk_size),
        cpus: project.cpus.or(user.cpus),
        memory: project.memory.or(user.memory),
        default_name: project.default_name.or(user.default_name),
        ports: merge_port_lists(user.ports, project.ports),
        project_mount: project.project_mount.or(user.project_mount),
    }
}

/// Merge mount lists from user and project configs (union, deduped by exact string).
fn merge_mount_lists(
    user: Option<Vec<String>>,
    project: Option<Vec<String>>,
) -> Option<Vec<String>> {
    match (user, project) {
        (None, None) => None,
        (Some(a), None) | (None, Some(a)) => Some(a),
        (Some(mut a), Some(b)) => {
            for m in b {
                if !a.contains(&m) {
                    a.push(m);
                }
            }
            Some(a)
        }
    }
}

/// Merge port lists from user and project configs (union, deduped by guest port).
fn merge_port_lists(
    user: Option<Vec<String>>,
    project: Option<Vec<String>>,
) -> Option<Vec<String>> {
    match (user, project) {
        (None, None) => None,
        (Some(a), None) | (None, Some(a)) => Some(a),
        (Some(mut a), Some(b)) => {
            for p in b {
                if !a.contains(&p) {
                    a.push(p);
                }
            }
            Some(a)
        }
    }
}

/// Merge CLI args with config files. CLI args take precedence.
pub fn resolve(
    cli_target: Option<&str>,
    cli_mounts: &[String],
    cli_disk_size: Option<&str>,
    cli_cpus: Option<u32>,
    cli_memory: Option<u32>,
    cli_ports: &[String],
    cli_no_project_mount: bool,
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

    // CLI mounts are additive with config mounts (union)
    let mut mounts = {
        let mut merged = config.mounts.unwrap_or_default();
        for m in cli_mounts {
            if !merged.contains(m) {
                merged.push(m.clone());
            }
        }
        merged
    };

    // Auto-mount project directory when in a project and not disabled
    let auto_mount = if cli_no_project_mount {
        false
    } else {
        config.project_mount.unwrap_or(true)
    };
    if auto_mount && let Some(ref dir) = project_dir()? {
        let already_mounted = mounts.iter().any(|m| {
            Path::new(m)
                .canonicalize()
                .map(|p| p.to_string_lossy().to_string())
                .unwrap_or_else(|_| m.clone())
                == *dir
        });
        if !already_mounted {
            mounts.insert(0, dir.clone());
        }
    }

    let disk_size = cli_disk_size
        .map(|s| s.to_string())
        .or(config.disk_size)
        .unwrap_or_else(|| "40G".to_string());

    let cpus = cli_cpus.or(config.cpus);
    let memory = cli_memory.or(config.memory);
    let default_name = config.default_name.unwrap_or_else(|| "default".to_string());

    // CLI ports are merged with config ports (union)
    let config_ports = config.ports.unwrap_or_default();
    let mut ports = config_ports;
    for p in cli_ports {
        if !ports.contains(p) {
            ports.push(p.clone());
        }
    }

    Ok(Resolved {
        target,
        mounts,
        disk_size,
        cpus,
        memory,
        default_name,
        ports,
    })
}

/// Resolve the default instance name from config, falling back to "default".
pub fn resolve_default_name() -> Result<String> {
    let user = load_user()?;
    let project = load_project()?;
    let config = merge_configs(user, project);
    Ok(config.default_name.unwrap_or_else(|| "default".to_string()))
}

/// Generate a TOML config string from a Config struct.
/// Only includes fields that are Some.
pub fn generate_toml(config: &Config) -> String {
    let mut lines = Vec::new();
    if let Some(ref target) = config.target {
        lines.push(format!("target = {}", toml::Value::String(target.clone())));
    }
    if let Some(ref default_name) = config.default_name {
        lines.push(format!(
            "default_name = {}",
            toml::Value::String(default_name.clone())
        ));
    }
    if let Some(cpus) = config.cpus {
        lines.push(format!("cpus = {cpus}"));
    }
    if let Some(memory) = config.memory {
        lines.push(format!("memory = {memory}"));
    }
    if !lines.is_empty() {
        lines.push(String::new()); // trailing newline
    }
    lines.join("\n")
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
    fn parse_cpus_and_memory() {
        let toml = r#"
cpus = 4
memory = 2048
"#;
        let config = parse(toml, Path::new("/")).unwrap();
        assert_eq!(config.cpus.unwrap(), 4);
        assert_eq!(config.memory.unwrap(), 2048);
    }

    #[test]
    fn parse_default_name() {
        let toml = r#"default_name = "dev""#;
        let config = parse(toml, Path::new("/")).unwrap();
        assert_eq!(config.default_name.unwrap(), "dev");
    }

    #[test]
    fn parse_cpus_memory_default_name_absent() {
        let toml = r#"target = ".#dev""#;
        let config = parse(toml, Path::new("/")).unwrap();
        assert!(config.cpus.is_none());
        assert!(config.memory.is_none());
        assert!(config.default_name.is_none());
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
            ..Config::default()
        };
        let project = Config {
            target: Some(".#project".into()),
            ..Config::default()
        };
        let merged = merge_configs(Some(user), Some(project));
        assert_eq!(merged.target.unwrap(), ".#project");
        // mounts falls through to user
        assert_eq!(merged.mounts.unwrap(), vec!["/user/mount"]);
        assert_eq!(merged.disk_size.unwrap(), "30G");
    }

    #[test]
    fn merge_mounts_union() {
        let user = Config {
            mounts: Some(vec!["/user/dotfiles".into()]),
            ..Config::default()
        };
        let project = Config {
            mounts: Some(vec!["/project/src".into()]),
            ..Config::default()
        };
        let merged = merge_configs(Some(user), Some(project));
        let mounts = merged.mounts.unwrap();
        assert_eq!(mounts.len(), 2);
        assert!(mounts.contains(&"/user/dotfiles".to_string()));
        assert!(mounts.contains(&"/project/src".to_string()));
    }

    #[test]
    fn merge_mounts_dedup() {
        let user = Config {
            mounts: Some(vec!["/shared/mount".into()]),
            ..Config::default()
        };
        let project = Config {
            mounts: Some(vec!["/shared/mount".into(), "/project/only".into()]),
            ..Config::default()
        };
        let merged = merge_configs(Some(user), Some(project));
        let mounts = merged.mounts.unwrap();
        assert_eq!(mounts.len(), 2);
        assert!(mounts.contains(&"/shared/mount".to_string()));
        assert!(mounts.contains(&"/project/only".to_string()));
    }

    #[test]
    fn merge_mounts_one_side_none() {
        let user = Config {
            mounts: Some(vec!["/user/mount".into()]),
            ..Config::default()
        };
        let merged = merge_configs(Some(user), None);
        assert_eq!(merged.mounts.unwrap(), vec!["/user/mount"]);
    }

    #[test]
    fn merge_user_only() {
        let user = Config {
            target: Some(".#user".into()),
            ..Config::default()
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
    fn merge_cpus_memory_project_overrides_user() {
        let user = Config {
            cpus: Some(2),
            memory: Some(1024),
            default_name: Some("uservm".into()),
            ..Config::default()
        };
        let project = Config {
            cpus: Some(4),
            memory: None,
            default_name: Some("projvm".into()),
            ..Config::default()
        };
        let merged = merge_configs(Some(user), Some(project));
        assert_eq!(merged.cpus.unwrap(), 4);
        assert_eq!(merged.memory.unwrap(), 1024); // falls through to user
        assert_eq!(merged.default_name.unwrap(), "projvm");
    }

    #[test]
    fn merge_cpus_memory_user_only() {
        let user = Config {
            cpus: Some(8),
            memory: Some(4096),
            default_name: Some("myvm".into()),
            ..Config::default()
        };
        let merged = merge_configs(Some(user), None);
        assert_eq!(merged.cpus.unwrap(), 8);
        assert_eq!(merged.memory.unwrap(), 4096);
        assert_eq!(merged.default_name.unwrap(), "myvm");
    }

    #[test]
    fn merge_cpus_memory_none() {
        let merged = merge_configs(None, None);
        assert!(merged.cpus.is_none());
        assert!(merged.memory.is_none());
        assert!(merged.default_name.is_none());
    }

    #[test]
    fn resolve_default_name_from_config() {
        // When config has default_name, resolve should use it
        let config = merge_configs(
            Some(Config {
                default_name: Some("dev".into()),
                ..Config::default()
            }),
            None,
        );
        assert_eq!(config.default_name.unwrap(), "dev");
    }

    #[test]
    fn generate_toml_full() {
        let config = Config {
            target: Some(".#dev".into()),
            default_name: Some("myvm".into()),
            cpus: Some(4),
            memory: Some(2048),
            ..Config::default()
        };
        let toml_str = generate_toml(&config);
        assert!(toml_str.contains("target = \".#dev\""));
        assert!(toml_str.contains("default_name = \"myvm\""));
        assert!(toml_str.contains("cpus = 4"));
        assert!(toml_str.contains("memory = 2048"));

        // Round-trip: parse the generated TOML
        let parsed = parse(&toml_str, Path::new("/")).unwrap();
        assert_eq!(parsed.target.unwrap(), ".#dev");
        assert_eq!(parsed.default_name.unwrap(), "myvm");
        assert_eq!(parsed.cpus.unwrap(), 4);
        assert_eq!(parsed.memory.unwrap(), 2048);
    }

    #[test]
    fn generate_toml_target_only() {
        let config = Config {
            target: Some(".#dev".into()),
            ..Config::default()
        };
        let toml_str = generate_toml(&config);
        assert!(toml_str.contains("target = \".#dev\""));
        assert!(!toml_str.contains("default_name"));
        assert!(!toml_str.contains("cpus"));
        assert!(!toml_str.contains("memory"));
    }

    #[test]
    fn generate_toml_empty() {
        let config = Config::default();
        let toml_str = generate_toml(&config);
        assert_eq!(toml_str, "");
    }

    #[test]
    fn resolve_default_name_fallback() {
        // When no config sets default_name, it should fall back to "default"
        let config = merge_configs(None, None);
        let default_name = config.default_name.unwrap_or_else(|| "default".to_string());
        assert_eq!(default_name, "default");
    }

    #[test]
    fn parse_ports_config() {
        let toml = r#"
ports = ["8080:80", ":443"]
"#;
        let config = parse(toml, Path::new("/")).unwrap();
        assert_eq!(config.ports.unwrap(), vec!["8080:80", ":443"]);
    }

    #[test]
    fn parse_no_ports_config() {
        let toml = r#"target = ".#dev""#;
        let config = parse(toml, Path::new("/")).unwrap();
        assert!(config.ports.is_none());
    }

    #[test]
    fn merge_ports_union() {
        let user = Config {
            ports: Some(vec!["8080:80".into()]),
            ..Config::default()
        };
        let project = Config {
            ports: Some(vec![":443".into()]),
            ..Config::default()
        };
        let merged = merge_configs(Some(user), Some(project));
        let ports = merged.ports.unwrap();
        assert_eq!(ports.len(), 2);
        assert!(ports.contains(&"8080:80".to_string()));
        assert!(ports.contains(&":443".to_string()));
    }

    #[test]
    fn merge_ports_dedup() {
        let user = Config {
            ports: Some(vec!["8080:80".into()]),
            ..Config::default()
        };
        let project = Config {
            ports: Some(vec!["8080:80".into(), ":443".into()]),
            ..Config::default()
        };
        let merged = merge_configs(Some(user), Some(project));
        let ports = merged.ports.unwrap();
        assert_eq!(ports.len(), 2);
    }

    #[test]
    fn merge_ports_one_side_none() {
        let user = Config {
            ports: Some(vec!["8080:80".into()]),
            ..Config::default()
        };
        let merged = merge_configs(Some(user), None);
        assert_eq!(merged.ports.unwrap(), vec!["8080:80"]);
    }

    #[test]
    fn parse_project_mount_false() {
        let toml = r#"project_mount = false"#;
        let config = parse(toml, Path::new("/")).unwrap();
        assert_eq!(config.project_mount, Some(false));
    }

    #[test]
    fn parse_project_mount_true() {
        let toml = r#"project_mount = true"#;
        let config = parse(toml, Path::new("/")).unwrap();
        assert_eq!(config.project_mount, Some(true));
    }

    #[test]
    fn parse_project_mount_absent() {
        let toml = r#"target = ".#dev""#;
        let config = parse(toml, Path::new("/")).unwrap();
        assert!(config.project_mount.is_none());
    }

    #[test]
    fn merge_project_mount_project_overrides_user() {
        let user = Config {
            project_mount: Some(true),
            ..Config::default()
        };
        let project = Config {
            project_mount: Some(false),
            ..Config::default()
        };
        let merged = merge_configs(Some(user), Some(project));
        assert_eq!(merged.project_mount, Some(false));
    }

    #[test]
    fn merge_project_mount_falls_through_to_user() {
        let user = Config {
            project_mount: Some(false),
            ..Config::default()
        };
        let merged = merge_configs(Some(user), None);
        assert_eq!(merged.project_mount, Some(false));
    }

    #[test]
    fn merge_project_mount_none_when_unset() {
        let merged = merge_configs(None, None);
        assert!(merged.project_mount.is_none());
    }

    #[test]
    fn resolve_cli_mounts_additive() {
        // CLI mounts are merged with config mounts (union)
        let config = merge_configs(
            Some(Config {
                target: Some(".#fromconfig".into()),
                mounts: Some(vec!["/config/mount".into()]),
                disk_size: Some("30G".into()),
                ..Config::default()
            }),
            None,
        );

        // CLI target overrides
        let target = Some(".#fromcli").map(|s| s.to_string()).or(config.target);
        assert_eq!(target.unwrap(), ".#fromcli");

        // CLI mounts are additive with config mounts
        let cli_mounts = vec!["/cli/mount".to_string()];
        let config_mounts = config.mounts.unwrap_or_default();
        let mut mounts = config_mounts;
        for m in &cli_mounts {
            if !mounts.contains(m) {
                mounts.push(m.clone());
            }
        }
        assert_eq!(mounts.len(), 2);
        assert!(mounts.contains(&"/config/mount".to_string()));
        assert!(mounts.contains(&"/cli/mount".to_string()));
    }
}
