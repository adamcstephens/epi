use anyhow::{Context, Result, bail};
use std::process::Command;

#[derive(Debug)]
pub struct Output {
    pub status: i32,
    pub stdout: String,
    pub stderr: String,
}

impl Output {
    pub fn success(&self) -> bool {
        self.status == 0
    }
}

pub fn run(prog: &str, args: &[&str]) -> Result<Output> {
    run_with_env(prog, args, &[])
}

pub fn run_with_env(prog: &str, args: &[&str], env: &[(&str, &str)]) -> Result<Output> {
    let mut cmd = Command::new(prog);
    cmd.args(args);
    for (k, v) in env {
        cmd.env(k, v);
    }
    let output = cmd
        .output()
        .with_context(|| format!("failed to execute {prog}"))?;

    let status = output.status.code().unwrap_or(128);
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();

    Ok(Output {
        status,
        stdout,
        stderr,
    })
}

pub fn generate_unit_id() -> String {
    use rand::Rng;
    let mut rng = rand::rng();
    let bytes: [u8; 4] = rng.random();
    hex_encode(&bytes)
}

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

pub fn escape_unit_name(name: &str) -> Result<String> {
    let out = run("systemd-escape", &[name])?;
    if !out.success() {
        bail!("systemd-escape failed: {}", out.stderr);
    }
    Ok(out.stdout)
}

pub fn systemd_run_bin() -> String {
    std::env::var("EPI_SYSTEMD_RUN_BIN").unwrap_or_else(|_| "systemd-run".to_string())
}

pub fn systemctl_bin() -> String {
    std::env::var("EPI_SYSTEMCTL_BIN")
        .unwrap_or_else(|_| "/run/current-system/sw/bin/systemctl".to_string())
}

pub fn run_helper(unit_name: &str, slice: &str, prog: &str, args: &[&str]) -> Result<Output> {
    let unit_arg = format!("--unit={unit_name}");
    let slice_arg = format!("--slice={slice}");
    let mut cmd_args: Vec<String> = vec![
        "--user".to_string(),
        "--collect".to_string(),
        unit_arg,
        slice_arg,
    ];

    // Forward current environment
    let env_args: Vec<String> = std::env::vars()
        .map(|(k, v)| format!("--setenv={k}={v}"))
        .collect();
    cmd_args.extend(env_args);

    cmd_args.push("--".to_string());
    cmd_args.push(prog.to_string());
    cmd_args.extend(args.iter().map(|s| s.to_string()));

    let refs: Vec<&str> = cmd_args.iter().map(|s| s.as_str()).collect();
    run(&systemd_run_bin(), &refs)
}

pub fn run_service(
    unit_name: &str,
    slice: &str,
    exec_stop_posts: &[&str],
    prog: &str,
    args: &[&str],
) -> Result<Output> {
    let unit_arg = format!("--unit={unit_name}");
    let slice_arg = format!("--slice={slice}");
    let mut cmd_args: Vec<String> = vec![
        "--user".to_string(),
        "--collect".to_string(),
        unit_arg,
        slice_arg,
        "--property=Type=exec".to_string(),
    ];

    for stop_post in exec_stop_posts {
        cmd_args.push(format!("--property=ExecStopPost={stop_post}"));
    }

    let env_args: Vec<String> = std::env::vars()
        .map(|(k, v)| format!("--setenv={k}={v}"))
        .collect();
    cmd_args.extend(env_args);

    cmd_args.push("--".to_string());
    cmd_args.push(prog.to_string());
    cmd_args.extend(args.iter().map(|s| s.to_string()));

    let refs: Vec<&str> = cmd_args.iter().map(|s| s.as_str()).collect();
    run(&systemd_run_bin(), &refs)
}

pub fn journal_for_unit(unit_name: &str) -> Result<String> {
    let out = run(
        "journalctl",
        &["--user", "--unit", unit_name, "--no-pager", "--output=cat"],
    )?;
    Ok(out.stdout)
}

pub fn unit_is_active(unit_name: &str) -> Result<bool> {
    let out = run(&systemctl_bin(), &["--user", "is-active", unit_name])?;
    Ok(out.stdout == "active")
}

pub fn stop_unit(unit_name: &str) -> Result<bool> {
    let out = run(&systemctl_bin(), &["--user", "stop", unit_name])?;
    Ok(out.success())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unit_id_is_8_hex_chars() {
        let id = generate_unit_id();
        assert_eq!(id.len(), 8);
        assert!(id.chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    fn unit_ids_are_unique() {
        let a = generate_unit_id();
        let b = generate_unit_id();
        assert_ne!(a, b);
    }

    #[test]
    fn hex_encode_works() {
        assert_eq!(hex_encode(&[0xde, 0xad, 0xbe, 0xef]), "deadbeef");
        assert_eq!(hex_encode(&[0x00, 0xff]), "00ff");
    }

    #[test]
    fn run_captures_stdout() {
        let out = run("echo", &["hello"]).unwrap();
        assert!(out.success());
        assert_eq!(out.stdout, "hello");
    }

    #[test]
    fn run_captures_exit_code() {
        let out = run("false", &[]).unwrap();
        assert!(!out.success());
        assert_eq!(out.status, 1);
    }

    #[test]
    fn run_with_env_sets_vars() {
        let out = run_with_env("sh", &["-c", "echo $TEST_VAR"], &[("TEST_VAR", "works")]).unwrap();
        assert_eq!(out.stdout, "works");
    }
}
