use anyhow::Result;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use crate::process;

pub struct HookEnv {
    pub instance_name: String,
    pub ssh_port: u16,
    pub ssh_key_path: String,
    pub ssh_user: String,
    pub state_dir: String,
}

fn user_hooks_dir() -> PathBuf {
    if let Ok(xdg) = std::env::var("XDG_CONFIG_HOME") {
        PathBuf::from(xdg).join("epi/hooks")
    } else if let Ok(home) = std::env::var("HOME") {
        PathBuf::from(home).join(".config/epi/hooks")
    } else {
        PathBuf::from(".config/epi/hooks")
    }
}

fn project_hooks_dir() -> PathBuf {
    if let Ok(dir) = std::env::var("EPI_PROJECT_HOOKS_DIR") {
        PathBuf::from(dir)
    } else {
        PathBuf::from(".epi/hooks")
    }
}

fn discover_scripts(dir: &Path) -> Result<Vec<PathBuf>> {
    if !dir.exists() {
        return Ok(vec![]);
    }
    let mut scripts = vec![];
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let name = entry.file_name();
        let name_str = name.to_string_lossy();
        if name_str.starts_with('.') {
            continue;
        }
        let ft = entry.file_type()?;
        if ft.is_dir() {
            continue;
        }
        let meta = entry.metadata()?;
        let mode = meta.permissions().mode();
        if mode & 0o111 != 0 {
            scripts.push(entry.path());
        } else {
            eprintln!(
                "warning: hook {} is not executable, skipping",
                entry.path().display()
            );
        }
    }
    scripts.sort();
    Ok(scripts)
}

/// Discover guest-init hooks for seed ISO
pub fn discover_guest(instance_name: &str) -> Result<Vec<PathBuf>> {
    let mut hooks = vec![];
    for base in [user_hooks_dir(), project_hooks_dir()] {
        let top = base.join("guest-init.d");
        hooks.extend(discover_scripts(&top)?);
        hooks.extend(discover_scripts(&top.join(instance_name))?);
    }
    Ok(hooks)
}

/// Discover hooks for a given hook point (post-launch, pre-stop)
pub fn discover(
    instance_name: &str,
    nix_hooks: &[String],
    hook_point: &str,
) -> Result<Vec<PathBuf>> {
    let mut hooks = vec![];

    for base in [user_hooks_dir(), project_hooks_dir()] {
        let top = base.join(format!("{hook_point}.d"));
        hooks.extend(discover_scripts(&top)?);
        hooks.extend(discover_scripts(&top.join(instance_name))?);
    }

    // Nix-provided hooks
    for path in nix_hooks {
        let p = PathBuf::from(path);
        if p.exists() {
            hooks.push(p);
        } else {
            eprintln!("warning: nix hook {path} does not exist, skipping");
        }
    }

    Ok(hooks)
}

/// Discover scripts from a given directory. Exposed for testing.
pub fn discover_scripts_from(dir: &Path) -> Result<Vec<PathBuf>> {
    discover_scripts(dir)
}

/// Execute hooks in sequence, failing on first error
pub fn execute(env: &HookEnv, scripts: &[PathBuf]) -> Result<()> {
    let epi_bin = std::env::current_exe()
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|_| "epi".to_string());

    let port_str = env.ssh_port.to_string();
    let env_vars: Vec<(&str, &str)> = vec![
        ("EPI_INSTANCE", &env.instance_name),
        ("EPI_SSH_PORT", &port_str),
        ("EPI_SSH_KEY", &env.ssh_key_path),
        ("EPI_SSH_USER", &env.ssh_user),
        ("EPI_STATE_DIR", &env.state_dir),
        ("EPI_BIN", &epi_bin),
    ];

    for script in scripts {
        let script_str = script.to_string_lossy();
        eprintln!("running hook: {script_str}");
        let out = process::run_with_env(&script_str, &[], &env_vars)?;
        if !out.success() {
            anyhow::bail!(
                "hook {} failed (exit {}): {}",
                script_str,
                out.status,
                out.stderr
            );
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use tempfile::TempDir;

    fn make_executable(path: &Path) {
        fs::write(path, "#!/bin/sh\ntrue\n").unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
    }

    fn make_non_executable(path: &Path) {
        fs::write(path, "not a script").unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o644)).unwrap();
    }

    #[test]
    fn discover_finds_executables() {
        let dir = TempDir::new().unwrap();
        make_executable(&dir.path().join("01-first.sh"));
        make_executable(&dir.path().join("02-second.sh"));
        make_non_executable(&dir.path().join("readme.txt"));

        let scripts = discover_scripts_from(dir.path()).unwrap();
        assert_eq!(scripts.len(), 2);
        assert!(scripts[0].ends_with("01-first.sh"));
        assert!(scripts[1].ends_with("02-second.sh"));
    }

    #[test]
    fn discover_ignores_dotfiles() {
        let dir = TempDir::new().unwrap();
        make_executable(&dir.path().join(".hidden"));
        make_executable(&dir.path().join("visible"));

        let scripts = discover_scripts_from(dir.path()).unwrap();
        assert_eq!(scripts.len(), 1);
        assert!(scripts[0].ends_with("visible"));
    }

    #[test]
    fn discover_ignores_directories() {
        let dir = TempDir::new().unwrap();
        fs::create_dir(dir.path().join("subdir")).unwrap();
        make_executable(&dir.path().join("script.sh"));

        let scripts = discover_scripts_from(dir.path()).unwrap();
        assert_eq!(scripts.len(), 1);
    }

    #[test]
    fn discover_returns_sorted() {
        let dir = TempDir::new().unwrap();
        make_executable(&dir.path().join("c-third"));
        make_executable(&dir.path().join("a-first"));
        make_executable(&dir.path().join("b-second"));

        let scripts = discover_scripts_from(dir.path()).unwrap();
        let names: Vec<&str> = scripts
            .iter()
            .map(|p| p.file_name().unwrap().to_str().unwrap())
            .collect();
        assert_eq!(names, vec!["a-first", "b-second", "c-third"]);
    }

    #[test]
    fn discover_empty_dir() {
        let dir = TempDir::new().unwrap();
        let scripts = discover_scripts_from(dir.path()).unwrap();
        assert!(scripts.is_empty());
    }

    #[test]
    fn discover_nonexistent_dir() {
        let scripts = discover_scripts_from(Path::new("/nonexistent/dir")).unwrap();
        assert!(scripts.is_empty());
    }

    #[test]
    fn execute_runs_scripts_in_order() {
        let dir = TempDir::new().unwrap();
        let log = dir.path().join("log.txt");
        let log_path = log.to_string_lossy();

        let script1 = dir.path().join("01.sh");
        fs::write(&script1, format!("#!/bin/sh\necho first >> {log_path}\n")).unwrap();
        fs::set_permissions(&script1, fs::Permissions::from_mode(0o755)).unwrap();

        let script2 = dir.path().join("02.sh");
        fs::write(&script2, format!("#!/bin/sh\necho second >> {log_path}\n")).unwrap();
        fs::set_permissions(&script2, fs::Permissions::from_mode(0o755)).unwrap();

        let env = HookEnv {
            instance_name: "test".into(),
            ssh_port: 2222,
            ssh_key_path: "/tmp/key".into(),
            ssh_user: "root".into(),
            state_dir: "/tmp/state".into(),
        };
        execute(&env, &[script1, script2]).unwrap();

        let output = fs::read_to_string(&log).unwrap();
        assert_eq!(output.trim(), "first\nsecond");
    }

    #[test]
    fn execute_fails_on_bad_script() {
        let dir = TempDir::new().unwrap();
        let script = dir.path().join("fail.sh");
        fs::write(&script, "#!/bin/sh\nexit 1\n").unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();

        let env = HookEnv {
            instance_name: "test".into(),
            ssh_port: 2222,
            ssh_key_path: "/tmp/key".into(),
            ssh_user: "root".into(),
            state_dir: "/tmp/state".into(),
        };
        let result = execute(&env, &[script]);
        assert!(result.is_err());
    }
}
