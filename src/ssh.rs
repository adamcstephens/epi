use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{Result, bail};

use crate::instance_store;
use crate::process;

pub fn user() -> String {
    std::env::var("USER").unwrap_or_else(|_| "user".to_string())
}

/// Returns the path to the SSH config file for an instance.
pub fn config_path(instance: &str) -> PathBuf {
    instance_store::instance_path(instance, "ssh_config")
}

/// Generate an SSH config file for an instance and write it to the given path.
///
/// When `known_hosts` is `None`, host key checking is disabled (for initial boot).
/// When `Some(path)`, strict host key checking is enabled using the given known_hosts file.
pub fn generate_config(
    output: &Path,
    instance: &str,
    ssh_port: u16,
    username: &str,
    ssh_key_path: &Path,
    known_hosts: Option<&Path>,
) -> Result<()> {
    let (strict_checking, known_hosts_file) = match known_hosts {
        Some(path) => ("yes", path.display().to_string()),
        None => ("no", "/dev/null".to_string()),
    };
    let contents = format!(
        "Host {instance}\n\
         \x20   HostName 127.0.0.1\n\
         \x20   Port {ssh_port}\n\
         \x20   User {username}\n\
         \x20   IdentityFile {key}\n\
         \x20   IdentitiesOnly yes\n\
         \x20   StrictHostKeyChecking {strict_checking}\n\
         \x20   UserKnownHostsFile {known_hosts_file}\n\
         \x20   LogLevel ERROR\n",
        key = ssh_key_path.display(),
    );
    std::fs::write(output, &contents)?;
    Ok(())
}

/// Returns the path to the known_hosts file for an instance.
pub fn known_hosts_path(instance: &str) -> PathBuf {
    instance_store::instance_path(instance, "known_hosts")
}

/// Record the guest's SSH host key using ssh-keyscan.
///
/// Returns `true` if the key was successfully recorded, `false` if keyscan failed.
/// Does not return an error on keyscan failure — the caller can fall back to the
/// untrusted config.
pub fn record_host_key(ssh_port: u16, known_hosts: &Path) -> Result<bool> {
    let port_str = ssh_port.to_string();
    let out = process::run("ssh-keyscan", &["-p", &port_str, "127.0.0.1"])?;

    if !out.success() || out.stdout.is_empty() {
        return Ok(false);
    }

    std::fs::write(known_hosts, &out.stdout)?;
    Ok(true)
}

/// Record the guest host key and rewrite the SSH config to enable strict checking.
///
/// If keyscan fails, logs a warning and leaves the untrusted config in place.
pub fn trust_host_key(
    instance: &str,
    ssh_port: u16,
    username: &str,
    ssh_key_path: &Path,
) -> Result<()> {
    let known_hosts = known_hosts_path(instance);
    if record_host_key(ssh_port, &known_hosts)? {
        generate_config(
            &config_path(instance),
            instance,
            ssh_port,
            username,
            ssh_key_path,
            Some(&known_hosts),
        )?;
    } else {
        eprintln!(
            "warning: could not record host key for {instance}, keeping untrusted SSH config"
        );
    }
    Ok(())
}

/// Poll until SSH is reachable via the config file, or timeout.
pub fn wait_for_ssh(config: &Path, instance: &str, timeout_seconds: u64) -> Result<()> {
    let start = std::time::Instant::now();
    let timeout = Duration::from_secs(timeout_seconds);
    let config_str = config.to_string_lossy();

    loop {
        if start.elapsed() >= timeout {
            bail!("SSH not reachable after {timeout_seconds}s — instance may still be booting");
        }

        let out = process::run(
            "ssh",
            &[
                "-F",
                &config_str,
                "-o",
                "BatchMode=yes",
                "-o",
                "ConnectTimeout=5",
                instance,
                "true",
            ],
        )?;

        if out.success() {
            return Ok(());
        }

        std::thread::sleep(Duration::from_secs(2));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_generate_config_untrusted() {
        let dir = tempfile::tempdir().unwrap();
        let config = dir.path().join("ssh_config");
        let key_path = Path::new("/home/adam/.epi/state/myvm/id_ed25519");

        generate_config(&config, "myvm", 12345, "adam", key_path, None).unwrap();

        let contents = std::fs::read_to_string(&config).unwrap();
        assert!(contents.starts_with("Host myvm\n"));
        assert!(contents.contains("HostName 127.0.0.1"));
        assert!(contents.contains("Port 12345"));
        assert!(contents.contains("User adam"));
        assert!(contents.contains(&format!("IdentityFile {}", key_path.display())));
        assert!(contents.contains("IdentitiesOnly yes"));
        assert!(contents.contains("StrictHostKeyChecking no"));
        assert!(contents.contains("UserKnownHostsFile /dev/null"));
        assert!(contents.contains("LogLevel ERROR"));

        // Verify it's valid SSH config format - all options indented under Host
        let lines: Vec<&str> = contents.lines().collect();
        assert!(!lines[0].starts_with(' '));
        for line in &lines[1..] {
            assert!(line.starts_with("    "));
        }
    }

    #[test]
    fn test_generate_config_trusted() {
        let dir = tempfile::tempdir().unwrap();
        let config = dir.path().join("ssh_config");
        let key_path = Path::new("/home/adam/.epi/state/myvm/id_ed25519");
        let known_hosts = dir.path().join("known_hosts");

        generate_config(&config, "myvm", 12345, "adam", key_path, Some(&known_hosts)).unwrap();

        let contents = std::fs::read_to_string(&config).unwrap();
        assert!(contents.contains("StrictHostKeyChecking yes"));
        assert!(contents.contains(&format!("UserKnownHostsFile {}", known_hosts.display())));
        // Should NOT contain the untrusted values
        assert!(!contents.contains("StrictHostKeyChecking no"));
        assert!(!contents.contains("UserKnownHostsFile /dev/null"));
    }
}
