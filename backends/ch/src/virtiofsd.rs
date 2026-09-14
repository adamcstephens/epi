use anyhow::{Context, Result, bail};

use epi_core::process;

use std::path::Path;
use std::time::{Duration, Instant};

fn virtiofsd_args<'a>(socket_path: &'a str, shared_dir: &'a str, read_only: bool) -> Vec<&'a str> {
    let mut args = vec![
        "--socket-path",
        socket_path,
        "--shared-dir",
        shared_dir,
        "--announce-submounts",
        "--sandbox",
        "namespace",
    ];
    if read_only {
        args.push("--readonly");
    }
    args
}

pub fn start_virtiofsd(
    unit_name: &str,
    slice: &str,
    vm_unit: Option<&str>,
    socket_path: &str,
    shared_dir: &str,
    read_only: bool,
) -> Result<()> {
    process::require_binary("virtiofsd", "virtiofsd")?;
    let args = virtiofsd_args(socket_path, shared_dir, read_only);
    let out = process::run_helper(unit_name, slice, vm_unit, "virtiofsd", &args)
        .with_context(|| format!("failed to start virtiofsd export {shared_dir}"))?;
    let deadline = Instant::now() + Duration::from_secs(2);
    let failure = if !out.success() {
        format!("failed to start unit {unit_name}: {}", out.stderr)
    } else {
        loop {
            let state = process::run(
                &process::systemctl_bin(),
                &["--user", "is-active", unit_name],
            )
            .with_context(|| format!("checking virtiofsd export {shared_dir}"))?;
            if !matches!(state.stdout.as_str(), "active" | "activating" | "reloading") {
                break format!("unit {unit_name} exited during startup ({})", state.stdout);
            }
            if Path::new(socket_path).exists() {
                return Ok(());
            }
            if Instant::now() >= deadline {
                break format!("socket did not appear: {socket_path}");
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    };
    let journal = process::journal_for_unit(unit_name)
        .with_context(|| format!("virtiofsd export {shared_dir}: {failure}; reading journal"))?;
    bail!("virtiofsd export {shared_dir}: {failure}\n{journal}");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn read_only_exports_pass_readonly_argument() {
        assert_eq!(
            virtiofsd_args("/tmp/virtiofs.sock", "/host/path", true),
            vec![
                "--socket-path",
                "/tmp/virtiofs.sock",
                "--shared-dir",
                "/host/path",
                "--announce-submounts",
                "--sandbox",
                "namespace",
                "--readonly",
            ]
        );
    }

    #[test]
    fn writable_exports_omit_readonly_argument() {
        assert!(!virtiofsd_args("/tmp/virtiofs.sock", "/host/path", false).contains(&"--readonly"));
        assert!(
            virtiofsd_args("/tmp/virtiofs.sock", "/host/path", false)
                .windows(2)
                .any(|args| args == ["--sandbox", "namespace"])
        );
    }

    #[test]
    #[ignore = "requires virtiofsd and a systemd user session"]
    fn failed_export_reports_journal_before_socket_timeout() {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("virtiofs.sock");
        let export = dir.path().join("missing-export");
        let unit = format!("epi-test-virtiofsd-{}", process::generate_unit_id());
        let start = std::time::Instant::now();
        let error = start_virtiofsd(
            &unit,
            "app.slice",
            None,
            socket.to_str().unwrap(),
            export.to_str().unwrap(),
            false,
        )
        .unwrap_err();
        assert!(start.elapsed() < std::time::Duration::from_millis(1800));
        let error = format!("{error:#}");
        assert!(error.contains(export.to_str().unwrap()), "{error}");
        let journal = process::journal_for_unit(&unit).unwrap();
        let diagnostic = journal
            .lines()
            .find(|line| line.contains("ERROR virtiofsd"))
            .expect("virtiofsd should log the export failure");
        assert!(error.contains(diagnostic), "{error}");
    }
}
