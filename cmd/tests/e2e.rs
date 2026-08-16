//! E2E tests that launch real VMs.
//!
//! These require a working nix flake target and systemd user session.
//! Run with: cargo test --test e2e
//!
//! The target is read from EPI_E2E_TARGET (default: '.#manual-test' on Linux,
//! '.#manual-test-aarch64' on macOS where VZ runs aarch64 guests).
//!
//! The backend is platform-selected: cloud-hypervisor on Linux, the macOS
//! Virtualization.framework (VZ) backend on aarch64-darwin. Tests that assert
//! ch-specific internals (systemd units, passt, api.sock) are gated to Linux;
//! the rest drive whichever backend the platform provides via `runtime.ssh`.

use epi::{config, hooks, instance_store, process, ssh, target, vm_launch};
use std::fs;
use std::sync::LazyLock;
use tempfile::TempDir;

#[cfg(target_os = "linux")]
use epi::backend::ch;

fn e2e_target() -> String {
    std::env::var("EPI_E2E_TARGET").unwrap_or_else(|_| default_target().to_string())
}

#[cfg(target_os = "macos")]
fn default_target() -> &'static str {
    ".#manual-test-aarch64"
}

#[cfg(not(target_os = "macos"))]
fn default_target() -> &'static str {
    ".#manual-test"
}

static DESCRIPTOR: LazyLock<(String, target::Descriptor)> = LazyLock::new(|| {
    let t = e2e_target();
    eprintln!("Generating descriptor");
    let desc = target::resolve_descriptor(&t).expect("failed to resolve e2e target");
    target::ensure_paths_exist(&t, &desc).expect("e2e descriptor paths missing");
    eprintln!("Finished generating descriptor");
    (t, desc)
});

fn unique_name(prefix: &str) -> String {
    let id = &process::generate_unit_id()[..6];
    format!("{prefix}-{id}")
}

struct InstanceGuard {
    name: String,
}

impl InstanceGuard {
    fn new(name: &str) -> Self {
        Self {
            name: name.to_string(),
        }
    }
}

impl Drop for InstanceGuard {
    fn drop(&mut self) {
        if std::env::var("EPI_E2E_PAUSE").is_ok() {
            eprintln!(
                "== PAUSED: instance {} is running. Press Enter to continue teardown ==",
                self.name
            );
            let mut buf = String::new();
            let _ = std::io::stdin().read_line(&mut buf);
        }
        let _ = epi::backend::stop_instance(&self.name, true);
        let _ = instance_store::remove(&self.name);
    }
}

fn default_resolved() -> config::Resolved {
    let (target_str, _) = &*DESCRIPTOR;
    config::Resolved {
        target: target_str.clone(),
        mounts: vec![],
        disk_size: "40G".to_string(),
        cpus: 1,
        memory: 1024,
        default_name: "default".to_string(),
        ports: vec![],
        ssh_extra_config: vec![],
        project_config: None,
    }
}

fn provision_and_wait(name: &str) -> instance_store::RunningInstance {
    provision_and_wait_with(name, default_resolved())
}

fn provision_and_wait_with(
    name: &str,
    resolved: config::Resolved,
) -> instance_store::RunningInstance {
    instance_store::save_state(
        name,
        &instance_store::InstanceState {
            target: resolved.target.clone(),
            runtime: None,
            mounts: instance_store::canonicalize_mounts(&resolved.mounts),
            project_dir: None,
            disk_size: resolved.disk_size.clone(),
            cpus: resolved.cpus,
            memory_mib: resolved.memory,
            port_specs: resolved.ports.clone(),
            ssh_extra_config: resolved.ssh_extra_config.clone(),
            descriptor: None,
        },
    )
    .expect("save_state failed");

    let runtime = vm_launch::provision(&vm_launch::ProvisionParams {
        instance_name: name,
        target_str: &resolved.target,
        mounts: &resolved.mounts,
        disk_size: &resolved.disk_size,
        rebuild: false,
        cpus: resolved.cpus,
        memory_mib: resolved.memory,
        port_specs: &resolved.ports,
    })
    .expect("provision failed");

    instance_store::set_provisioned(name, runtime.clone(), None).expect("set_provisioned failed");

    ssh::generate_config(
        &ssh::config_path(name),
        name,
        runtime.ssh,
        &ssh::user(),
        std::path::Path::new(&runtime.ssh_key_path),
        None,
        &resolved.ssh_extra_config,
    )
    .expect("generate ssh config failed");
    ssh::wait_for_ssh(&ssh::config_path(name), name, 120).expect("ssh wait failed");

    runtime
}

fn ssh_user() -> String {
    std::env::var("USER").unwrap_or_else(|_| "epi".to_string())
}

fn ssh_exec(runtime: &instance_store::RunningInstance, cmd: &str) -> process::Output {
    let port = runtime.ssh.port().to_string();
    let user_host = format!("{}@{}", ssh_user(), runtime.ssh.ip());
    process::run(
        ssh::SSH_PROGRAM,
        &[
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "UserKnownHostsFile=/dev/null",
            "-o",
            "LogLevel=ERROR",
            "-o",
            "BatchMode=yes",
            "-i",
            &runtime.ssh_key_path,
            "-p",
            &port,
            &user_host,
            "--",
            cmd,
        ],
    )
    .expect("ssh exec failed")
}

// Exercises passt host-port forwarding and systemd unit internals; both are
// ch-only. VZ lifecycle (launch/ssh/stop/restart) is covered by e2e_stop_start_ssh.
#[cfg(target_os = "linux")]
#[test]
#[ignore] // requires real VM — run explicitly
fn e2e_lifecycle() {
    let name = unique_name("lifecycle");
    let _guard = InstanceGuard::new(&name);

    // Provision with a port mapping (:8080 = auto-allocate host, guest 8080)
    let mut resolved = default_resolved();
    resolved.ports = vec![":8080".to_string()];
    resolved.cpus = 2;
    resolved.memory = 512;
    let runtime = provision_and_wait_with(&name, resolved.clone());
    assert!(runtime.ssh.port() != 0);

    // Verify port mapping was stored in runtime
    assert_eq!(runtime.ports.len(), 1, "expected 1 port mapping");
    assert_eq!(runtime.ports[0].guest, 8080);
    assert!(runtime.ports[0].host > 0, "host port should be allocated");
    assert_eq!(runtime.ports[0].protocol, "tcp");

    // Verify port mapping persisted to state
    let loaded = instance_store::find_runtime(&name).unwrap().unwrap();
    assert_eq!(loaded.ports.len(), 1);
    assert_eq!(loaded.ports[0].guest, 8080);

    // Verify resolved VM params persisted in InstanceState
    let state = instance_store::load_state(&name).unwrap().unwrap();
    assert_eq!(state.disk_size, "40G");
    assert_eq!(state.port_specs, vec![":8080".to_string()]);
    assert_eq!(state.cpus, 2);
    assert_eq!(state.memory_mib, 512);

    // Verify passt was started with the additional port forwarding arg
    let unit_id = epi::backend::ch::ch_unit_id(&runtime).unwrap();
    let passt_unit = epi::backend::ch::systemd::passt_unit_name(&name, unit_id).unwrap();
    let passt_cmd = process::run(
        &process::systemctl_bin(),
        &["--user", "show", &passt_unit, "--property=ExecStart"],
    )
    .expect("failed to query passt unit");
    let host_port = runtime.ports[0].host;
    let expected_fwd = format!("{host_port}:8080");
    assert!(
        passt_cmd.stdout.contains(&expected_fwd),
        "passt should have --tcp-ports {expected_fwd}, got: {}",
        passt_cmd.stdout
    );

    // Verify SSH works
    let out = ssh_exec(&runtime, "echo hello");
    assert!(
        out.success(),
        "echo hello failed (exit {}): {}",
        out.status,
        out.stderr
    );
    assert_eq!(out.stdout, "hello");

    // Verify hostname
    let out = ssh_exec(&runtime, "hostname");
    assert!(
        out.success(),
        "hostname failed (exit {}): {}",
        out.status,
        out.stderr
    );

    // Verify instance is running
    assert!(epi::backend::instance_is_running(&name).unwrap());

    // Stop
    epi::backend::stop_instance(&name, false).expect("stop failed");

    // Verify runtime cleared
    assert!(instance_store::find_runtime(&name).unwrap().is_none());
    // Target still exists
    assert!(instance_store::find(&name).unwrap().is_some());

    // Restart (with same port mapping)
    let runtime2 = provision_and_wait_with(&name, resolved);
    assert_eq!(
        runtime2.ports.len(),
        1,
        "port mapping should persist across restart"
    );
    let out = ssh_exec(&runtime2, "echo back");
    assert!(
        out.success(),
        "echo back failed (exit {}): {}",
        out.status,
        out.stderr
    );
    assert_eq!(out.stdout, "back");

    // Remove
    epi::backend::stop_instance(&name, false).expect("stop failed");
    instance_store::remove(&name).expect("remove failed");
    assert!(instance_store::find(&name).unwrap().is_none());
}

#[test]
#[ignore]
fn e2e_ssh_config_trusted_after_launch() {
    let name = unique_name("sshcfg");
    let _guard = InstanceGuard::new(&name);

    let runtime = provision_and_wait(&name);

    // Record host key and rewrite config
    ssh::trust_host_key(
        &name,
        runtime.ssh,
        &ssh::user(),
        std::path::Path::new(&runtime.ssh_key_path),
        &[],
    )
    .expect("trust_host_key failed");

    // Verify known_hosts file was created
    let known_hosts = ssh::known_hosts_path(&name);
    assert!(known_hosts.exists(), "known_hosts file should exist");
    let kh_contents = std::fs::read_to_string(&known_hosts).unwrap();
    assert!(!kh_contents.is_empty(), "known_hosts should not be empty");

    // Verify SSH config was rewritten with trusted settings
    let config = ssh::config_path(&name);
    let config_contents = std::fs::read_to_string(&config).unwrap();
    assert!(
        config_contents.contains("StrictHostKeyChecking yes"),
        "config should have StrictHostKeyChecking yes, got:\n{config_contents}"
    );
    assert!(
        config_contents.contains(&format!("UserKnownHostsFile {}", known_hosts.display())),
        "config should reference known_hosts file, got:\n{config_contents}"
    );
    assert!(
        !config_contents.contains("StrictHostKeyChecking no"),
        "config should not have StrictHostKeyChecking no"
    );

    // Verify SSH still works with the trusted config
    let config_str = config.to_string_lossy();
    let out = process::run(
        ssh::SSH_PROGRAM,
        &["-F", &config_str, &name, "echo", "trusted"],
    )
    .unwrap();
    assert!(
        out.success(),
        "SSH with trusted config failed: {}",
        out.stderr
    );
    assert_eq!(out.stdout, "trusted");
}

#[test]
#[ignore]
fn e2e_console_log_captured() {
    let name = unique_name("console");
    let _guard = InstanceGuard::new(&name);

    let _runtime = provision_and_wait(&name);

    // Console output is now captured by cloud-hypervisor via --console file=console.log.
    // The file should exist and contain boot output from the virtio-console device (hvc0).
    let log_path = instance_store::console_log_path(&name);
    assert!(log_path.exists(), "console.log should exist");

    let content = fs::read_to_string(&log_path).unwrap_or_default();
    assert!(
        !content.is_empty(),
        "console.log should contain boot output"
    );
}

#[test]
#[ignore]
fn e2e_mount() {
    let name = unique_name("mount");
    let _guard = InstanceGuard::new(&name);
    let (target_str, _) = &*DESCRIPTOR;

    // Create two temp dirs with distinct markers to test multiple mounts.
    // Canonicalize the host paths: epi mounts the canonical path into the
    // guest, and on macOS the temp dir lives under /var → /private/var.
    let mount_dir_a = TempDir::new().unwrap();
    fs::write(mount_dir_a.path().join("marker.txt"), "mount-a").unwrap();
    let mount_path_a = fs::canonicalize(mount_dir_a.path())
        .unwrap()
        .to_string_lossy()
        .to_string();

    let mount_dir_b = TempDir::new().unwrap();
    fs::write(mount_dir_b.path().join("marker.txt"), "mount-b").unwrap();
    let mount_path_b = fs::canonicalize(mount_dir_b.path())
        .unwrap()
        .to_string_lossy()
        .to_string();

    let mounts = vec![mount_path_a.clone(), mount_path_b.clone()];

    instance_store::save_state(
        &name,
        &instance_store::InstanceState {
            target: target_str.to_string(),
            runtime: None,
            mounts: instance_store::canonicalize_mounts(&mounts),
            project_dir: None,
            disk_size: "40G".into(),
            cpus: 0,
            memory_mib: 0,
            port_specs: vec![],
            ssh_extra_config: vec![],
            descriptor: None,
        },
    )
    .unwrap();

    let runtime = vm_launch::provision(&vm_launch::ProvisionParams {
        instance_name: &name,
        target_str,
        mounts: &mounts,
        disk_size: "40G",
        rebuild: false,
        cpus: 1,
        memory_mib: 1024,
        port_specs: &[],
    })
    .expect("provision failed");

    instance_store::set_provisioned(&name, runtime.clone(), None).unwrap();

    ssh::generate_config(
        &ssh::config_path(&name),
        &name,
        runtime.ssh,
        &ssh::user(),
        std::path::Path::new(&runtime.ssh_key_path),
        None,
        &[],
    )
    .expect("generate ssh config failed");
    ssh::wait_for_ssh(&ssh::config_path(&name), &name, 120).expect("ssh wait failed");

    // Verify first mount
    let cat_a = format!("cat {}/marker.txt", mount_path_a);
    let out = ssh_exec(&runtime, &cat_a);
    assert!(
        out.success(),
        "cat mount-a marker failed (exit {}): {}",
        out.status,
        out.stderr
    );
    assert_eq!(out.stdout, "mount-a");

    // Verify second mount
    let cat_b = format!("cat {}/marker.txt", mount_path_b);
    let out = ssh_exec(&runtime, &cat_b);
    assert!(
        out.success(),
        "cat mount-b marker failed (exit {}): {}",
        out.status,
        out.stderr
    );
    assert_eq!(out.stdout, "mount-b");
}

#[test]
#[ignore]
fn e2e_mount_explicit_dst() {
    let name = unique_name("mountdst");
    let _guard = InstanceGuard::new(&name);

    let mount_dir = TempDir::new().unwrap();
    fs::write(mount_dir.path().join("marker.txt"), "explicit-dst").unwrap();
    let mount_path = fs::canonicalize(mount_dir.path())
        .unwrap()
        .to_string_lossy()
        .to_string();

    let mut resolved = default_resolved();
    resolved.mounts = vec![format!("{mount_path}:/workspace")];

    let runtime = provision_and_wait_with(&name, resolved);

    let out = ssh_exec(&runtime, "cat /workspace/marker.txt");
    assert!(
        out.success(),
        "cat marker at explicit dst failed (exit {}): {}",
        out.status,
        out.stderr
    );
    assert_eq!(out.stdout, "explicit-dst");

    // Not also reachable at the host-derived path when dst is overridden.
    let cat_host_path = format!("cat {mount_path}/marker.txt");
    let out = ssh_exec(&runtime, &cat_host_path);
    assert!(
        !out.success(),
        "marker should not be reachable at the host-derived path when dst is overridden"
    );
}

#[test]
#[ignore]
fn e2e_hooks() {
    let name = unique_name("hooks");
    let _guard = InstanceGuard::new(&name);
    let (_, desc) = &*DESCRIPTOR;

    // Set up a project-level post-launch hook
    let hooks_dir = TempDir::new().unwrap();
    let hook_dir = hooks_dir.path().join("post-launch.d").join(&name);
    fs::create_dir_all(&hook_dir).unwrap();

    let log_file = hooks_dir.path().join("hook.log");
    let log_path_str = log_file.to_string_lossy();
    let hook_script = hook_dir.join("01-test.sh");
    fs::write(
        &hook_script,
        format!("#!/bin/sh\necho \"hook ran for $EPI_INSTANCE\" > {log_path_str}\n"),
    )
    .unwrap();

    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(&hook_script, fs::Permissions::from_mode(0o755)).unwrap();

    // Point hook discovery at our temp dir
    unsafe { std::env::set_var("EPI_PROJECT_HOOKS_DIR", hooks_dir.path()) };

    let runtime = provision_and_wait(&name);

    // Run post-launch hooks manually
    let hook_scripts =
        hooks::discover(&name, &desc.hooks.post_launch_scripts(), "post-launch").unwrap();

    let ssh_port = runtime.ssh.port();
    let env = hooks::HookEnv {
        instance_name: name.clone(),
        ssh_host: "127.0.0.1".to_string(),
        ssh_port,
        ssh_key_path: runtime.ssh_key_path.clone(),
        ssh_user: "root".to_string(),
        state_dir: instance_store::state_dir().to_string_lossy().to_string(),
        project_dir: None,
    };
    hooks::execute(&env, &hook_scripts).expect("hook execution failed");

    // Verify hook ran
    assert!(log_file.exists(), "hook log should exist");
    let content = fs::read_to_string(&log_file).unwrap();
    assert!(
        content.contains(&format!("hook ran for {name}")),
        "hook log should contain instance name, got: {content}"
    );

    unsafe { std::env::remove_var("EPI_PROJECT_HOOKS_DIR") };
}

#[test]
#[ignore]
fn e2e_graceful_shutdown() {
    let name = unique_name("shutdown");
    let _guard = InstanceGuard::new(&name);

    let _runtime = provision_and_wait(&name);
    assert!(epi::backend::instance_is_running(&name).unwrap());

    // The cloud-hypervisor control socket (ch-only) should exist after launch.
    #[cfg(target_os = "linux")]
    {
        let inst_dir = instance_store::instance_dir(&name);
        let api_socket = inst_dir.join("api.sock");
        assert!(api_socket.exists(), "api.sock should exist after launch");
    }

    // Stop and measure time — should complete well under 90s
    let _start = std::time::Instant::now();
    epi::backend::stop_instance(&name, false).expect("stop failed");

    // ch reaches a clean ACPI poweroff fast. On VZ the guest doesn't react to
    // the stop request yet, so a graceful stop waits the full grace + force
    // fallback (epi-66); only assert the fast-path bound on cloud-hypervisor.
    #[cfg(target_os = "linux")]
    {
        let elapsed = _start.elapsed();
        assert!(
            elapsed.as_secs() < 30,
            "stop took {}s, expected < 30s (graceful shutdown should be fast)",
            elapsed.as_secs()
        );
    }

    assert!(!epi::backend::instance_is_running(&name).unwrap());
}

#[test]
#[ignore]
fn e2e_force_shutdown() {
    let name = unique_name("force-shutdown");
    let _guard = InstanceGuard::new(&name);

    let _runtime = provision_and_wait(&name);
    assert!(epi::backend::instance_is_running(&name).unwrap());

    // Force stop should be near-instant — no ACPI, just SIGKILL.
    let _start = std::time::Instant::now();
    epi::backend::stop_instance(&name, true).expect("force stop failed");

    // ch SIGKILLs immediately; VZ force-stop is not yet immediate (epi-8), so
    // only assert the near-instant bound on the cloud-hypervisor backend.
    #[cfg(target_os = "linux")]
    {
        let elapsed = _start.elapsed();
        assert!(
            elapsed.as_secs() < 2,
            "force stop took {:?}, expected < 2s",
            elapsed
        );
    }

    assert!(!epi::backend::instance_is_running(&name).unwrap());
}

#[cfg(target_os = "linux")] // asserts systemd unit state (ch-only)
#[test]
#[ignore]
fn e2e_clean_shutdown_stops_helpers() {
    let name = unique_name("cleanstop");
    let _guard = InstanceGuard::new(&name);

    let runtime = provision_and_wait(&name);
    let unit_id = epi::backend::ch::ch_unit_id(&runtime).unwrap();

    // Construct expected unit names
    let vm_unit = epi::backend::ch::systemd::vm_unit_name(&name, unit_id).unwrap();
    let passt_unit = epi::backend::ch::systemd::passt_unit_name(&name, unit_id).unwrap();
    let slice = epi::backend::ch::systemd::slice_name(&name, unit_id).unwrap();

    // All units should be active before stop
    assert!(
        process::unit_is_active(&vm_unit).unwrap(),
        "VM should be active"
    );
    assert!(
        process::unit_is_active(&passt_unit).unwrap(),
        "passt should be active"
    );
    assert!(
        process::unit_is_active(&slice).unwrap(),
        "slice should be active"
    );

    // Stop the instance
    epi::backend::stop_instance(&name, false).expect("stop failed");

    // All units should be inactive after stop
    assert!(
        !process::unit_is_active(&vm_unit).unwrap(),
        "VM should be inactive after stop"
    );
    assert!(
        !process::unit_is_active(&passt_unit).unwrap(),
        "passt should be inactive after stop"
    );
    assert!(
        !process::unit_is_active(&slice).unwrap(),
        "slice should be inactive after stop"
    );
}

#[test]
#[ignore]
fn e2e_stop_start_ssh() {
    let name = unique_name("stopstart");
    let _guard = InstanceGuard::new(&name);

    // Use a relative mount path to exercise canonicalization —
    // without the fix, "." gets written to epi.json as-is and the guest
    // mounts virtiofs at "/" (cwd of epi-init), breaking networking.
    let mut resolved = default_resolved();
    resolved.mounts = vec![".".to_string()];

    // First boot: provision and verify SSH
    let runtime = provision_and_wait_with(&name, resolved.clone());
    let out = ssh_exec(&runtime, "echo first-boot");
    assert!(
        out.success(),
        "first-boot SSH failed (exit {}): {}",
        out.status,
        out.stderr
    );
    assert_eq!(out.stdout, "first-boot");

    // Stop the VM
    epi::backend::stop_instance(&name, false).expect("stop failed");

    // Second boot: re-provision (reuses persistent disk) and verify SSH
    let runtime2 = provision_and_wait_with(&name, resolved);
    let out2 = ssh_exec(&runtime2, "echo second-boot");
    assert!(
        out2.success(),
        "second-boot SSH failed (exit {}): {}",
        out2.status,
        out2.stderr
    );
    assert_eq!(out2.stdout, "second-boot");
}

#[cfg(target_os = "linux")] // inspects systemd unit Environment (ch-only)
#[test]
#[ignore]
fn e2e_no_env_leak() {
    let name = unique_name("noenv");
    let _guard = InstanceGuard::new(&name);

    // Set a sentinel env var that should NOT appear in the systemd units
    let sentinel = "EPI_TEST_SENTINEL";
    unsafe { std::env::set_var(sentinel, "leaked") };

    let runtime = provision_and_wait(&name);
    let unit_id = epi::backend::ch::ch_unit_id(&runtime).unwrap();

    let vm_unit = epi::backend::ch::systemd::vm_unit_name(&name, unit_id).unwrap();
    let passt_unit = epi::backend::ch::systemd::passt_unit_name(&name, unit_id).unwrap();

    // Check VM service environment
    let vm_env = process::run(
        &process::systemctl_bin(),
        &["--user", "show", &vm_unit, "--property=Environment"],
    )
    .expect("failed to query VM unit environment");

    assert!(
        !vm_env.stdout.contains(sentinel),
        "VM unit should not contain sentinel env var, got: {}",
        vm_env.stdout
    );

    // Check passt service environment
    let passt_env = process::run(
        &process::systemctl_bin(),
        &["--user", "show", &passt_unit, "--property=Environment"],
    )
    .expect("failed to query passt unit environment");

    assert!(
        !passt_env.stdout.contains(sentinel),
        "passt unit should not contain sentinel env var, got: {}",
        passt_env.stdout
    );

    unsafe { std::env::remove_var(sentinel) };
}

#[cfg(target_os = "linux")] // relies on systemd PartOf= helper teardown (ch-only)
#[test]
#[ignore]
fn e2e_vm_crash_stops_helpers() {
    let name = unique_name("vmcrash");
    let _guard = InstanceGuard::new(&name);

    let runtime = provision_and_wait(&name);
    let unit_id = epi::backend::ch::ch_unit_id(&runtime).unwrap();

    let vm_unit = epi::backend::ch::systemd::vm_unit_name(&name, unit_id).unwrap();
    let passt_unit = epi::backend::ch::systemd::passt_unit_name(&name, unit_id).unwrap();

    // All units should be active
    assert!(
        process::unit_is_active(&vm_unit).unwrap(),
        "VM should be active"
    );
    assert!(
        process::unit_is_active(&passt_unit).unwrap(),
        "passt should be active"
    );

    // Kill the VM process directly (simulating a crash) by stopping just the VM unit
    process::stop_unit(&vm_unit).expect("failed to stop VM unit");

    // Wait for PartOf= propagation — systemd stops helpers asynchronously
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    loop {
        if !process::unit_is_active(&passt_unit).unwrap() {
            break;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "passt should be inactive after VM kill (PartOf= should propagate stop)"
        );
        std::thread::sleep(std::time::Duration::from_secs(1));
    }

    assert!(
        !process::unit_is_active(&vm_unit).unwrap(),
        "VM should be inactive after kill"
    );
}

#[cfg(target_os = "linux")] // drives systemd units + passt.sock cleanup (ch-only)
#[test]
#[ignore]
fn e2e_clear_stale_runtime_kills_lingering_helpers() {
    let name = unique_name("staleclean");
    let _guard = InstanceGuard::new(&name);

    let runtime = provision_and_wait(&name);
    let unit_id = epi::backend::ch::ch_unit_id(&runtime).unwrap().to_string();
    let vm_unit = epi::backend::ch::systemd::vm_unit_name(&name, &unit_id).unwrap();
    let passt_unit = epi::backend::ch::systemd::passt_unit_name(&name, &unit_id).unwrap();
    let inst_dir = instance_store::instance_dir(&name);
    let passt_sock = inst_dir.join("passt.sock");

    // Simulate a crashed VM with a leaked passt: kill only the VM main process
    // bypassing PartOf= propagation by sending SIGKILL directly to the VM unit's
    // main pid (so the slice doesn't trigger a clean stop of helpers).
    process::run(
        &process::systemctl_bin(),
        &[
            "--user",
            "kill",
            "--signal=SIGKILL",
            "--kill-whom=main",
            &vm_unit,
        ],
    )
    .expect("failed to send SIGKILL to VM");

    // Wait for VM unit to go inactive
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(15);
    while process::unit_is_active(&vm_unit).unwrap() {
        assert!(
            std::time::Instant::now() < deadline,
            "VM never went inactive"
        );
        std::thread::sleep(std::time::Duration::from_millis(200));
    }

    // Best-effort: at this point passt MAY have died via PartOf= or MAY still be
    // alive. Either way, clear_stale_runtime must guarantee it's gone and the
    // socket file is removed.
    ch::clear_stale_runtime(&name).expect("clear_stale_runtime failed");

    assert!(
        !process::unit_is_active(&passt_unit).unwrap(),
        "passt unit should be inactive after clear_stale_runtime"
    );
    assert!(
        !passt_sock.exists(),
        "passt.sock should be removed after clear_stale_runtime"
    );
    assert!(
        instance_store::find_runtime(&name).unwrap().is_none(),
        "runtime state should be cleared"
    );
}

#[test]
#[ignore]
fn e2e_cp_file_to_vm() {
    let name = unique_name("cp");
    let _guard = InstanceGuard::new(&name);

    let runtime = provision_and_wait(&name);
    let ssh_port = runtime.ssh.port();

    // Create a temp file to copy
    let tmp_dir = TempDir::new().unwrap();
    let src_file = tmp_dir.path().join("test-cp.txt");
    fs::write(&src_file, "epi-cp-test-content").unwrap();

    // Build rsync command matching cmd_cp's logic
    let ssh_cmd = format!(
        "{} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i {} -p {}",
        ssh::SSH_PROGRAM,
        runtime.ssh_key_path,
        ssh_port
    );
    let remote_dest = format!("{}@{}:/tmp/test-cp.txt", ssh_user(), runtime.ssh.ip());

    let out = process::run(
        "rsync",
        &[
            "--progress",
            "-e",
            &ssh_cmd,
            &src_file.to_string_lossy(),
            &remote_dest,
        ],
    )
    .expect("rsync failed");

    assert!(
        out.success(),
        "rsync failed (exit {}): {}",
        out.status,
        out.stderr
    );

    // Verify the file arrived
    let verify = ssh_exec(&runtime, "cat /tmp/test-cp.txt");
    assert!(
        verify.success(),
        "cat failed (exit {}): {}",
        verify.status,
        verify.stderr
    );
    assert_eq!(verify.stdout, "epi-cp-test-content");
}

#[test]
#[ignore]
fn e2e_memory_override() {
    let name = unique_name("memover");
    let _guard = InstanceGuard::new(&name);

    let mut resolved = default_resolved();
    resolved.memory = 2048;

    let runtime = provision_and_wait_with(&name, resolved);

    // Verify the guest sees ~2048 MiB of memory
    let out = ssh_exec(&runtime, "grep MemTotal /proc/meminfo");
    assert!(
        out.success(),
        "meminfo failed (exit {}): {}",
        out.status,
        out.stderr
    );

    // MemTotal is in kB; 2048 MiB = ~2097152 kB (minus kernel reserved)
    let mem_kb: u64 = out
        .stdout
        .split_whitespace()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .expect("failed to parse MemTotal");

    // Should be between 1800 MiB and 2100 MiB (kernel reserves some)
    let mem_mib = mem_kb / 1024;
    assert!(
        mem_mib >= 1800 && mem_mib <= 2100,
        "expected ~2048 MiB, got {mem_mib} MiB"
    );
}

#[test]
#[ignore]
fn e2e_nested_virtualization() {
    let name = unique_name("nested");
    let _guard = InstanceGuard::new(&name);

    let runtime = provision_and_wait(&name);

    // Nested virtualization is enabled unconditionally, so the guest kernel can
    // load kvm and expose /dev/kvm for running L2 VMs.
    let out = ssh_exec(&runtime, "test -e /dev/kvm && echo present");
    assert!(
        out.success(),
        "/dev/kvm should be present in the guest (exit {}): {}",
        out.status,
        out.stderr
    );
    assert_eq!(out.stdout, "present");
}

#[test]
#[ignore] // cloud-hypervisor crashes with boot>1 + vhost-user passt: https://github.com/cloud-hypervisor/cloud-hypervisor/issues/7766
fn e2e_cpus_override() {
    let name = unique_name("cpuover");
    let _guard = InstanceGuard::new(&name);

    let mut resolved = default_resolved();
    resolved.cpus = 2;

    let runtime = provision_and_wait_with(&name, resolved);

    // Verify the guest sees 2 CPUs
    let out = ssh_exec(&runtime, "nproc");
    assert!(
        out.success(),
        "nproc failed (exit {}): {}",
        out.status,
        out.stderr
    );
    assert_eq!(out.stdout, "2", "expected 2 CPUs, got {}", out.stdout);
}

#[test]
#[ignore]
fn e2e_upgrade_switch() {
    let name = unique_name("upgrade");
    let _guard = InstanceGuard::new(&name);
    let (target_str, desc) = &*DESCRIPTOR;

    let runtime = provision_and_wait(&name);

    // Record the current system toplevel on guest
    let out = ssh_exec(&runtime, "readlink /run/current-system");
    assert!(
        out.success(),
        "readlink failed (exit {}): {}",
        out.status,
        out.stderr
    );
    let pre_toplevel = out.stdout.clone();
    assert!(
        !pre_toplevel.is_empty(),
        "pre-upgrade toplevel should not be empty"
    );

    // Seed a stale descriptor so we can verify that a switch-mode upgrade
    // rewrites it. The descriptor controls what a later `epi start` boots,
    // so even a no-reboot upgrade must update it (epi-61).
    let mut stale = desc.clone();
    stale.cmdline = "console=ttyS0 init=/nix/store/stale-sentinel/init".to_string();
    instance_store::update_descriptor(&name, stale).expect("seeding stale descriptor failed");

    // Build toplevel so we know what the upgrade should activate.
    let toplevel = target::build_toplevel(target_str).expect("build_toplevel failed");
    assert!(
        std::path::Path::new(&toplevel).exists(),
        "toplevel path should exist: {toplevel}"
    );

    // Invoke `epi upgrade` (default mode: switch) via the CLI binary so we
    // exercise the real command flow. Override XDG_CONFIG_HOME to an empty
    // dir so the user's host-side hooks don't run during the test.
    let empty_xdg = TempDir::new().expect("tempdir failed");
    let xdg_str = empty_xdg.path().to_string_lossy().into_owned();
    let out = process::run_with_env(
        env!("CARGO_BIN_EXE_epi"),
        &["upgrade", &name],
        &[("XDG_CONFIG_HOME", &xdg_str)],
    )
    .expect("epi upgrade failed to spawn");
    assert!(
        out.success(),
        "epi upgrade failed (exit {}): {}\n{}",
        out.status,
        out.stderr,
        out.stdout
    );

    // Verify guest is still reachable and running the new toplevel
    let out = ssh_exec(&runtime, "readlink /run/current-system");
    assert!(
        out.success(),
        "post-upgrade readlink failed (exit {}): {}",
        out.status,
        out.stderr
    );
    assert_eq!(
        out.stdout, toplevel,
        "post-upgrade toplevel should match the built toplevel"
    );

    // The stored descriptor must point at the new toplevel so any reboot
    // (`epi start` after a stop) boots the upgraded system.
    let state = instance_store::load_state(&name)
        .expect("load_state failed")
        .expect("instance state missing after upgrade");
    let stored = state
        .descriptor
        .expect("descriptor missing after upgrade --mode switch");
    assert!(
        stored.cmdline.contains(&format!("init={toplevel}/init")),
        "descriptor cmdline should boot the new toplevel, got: {}",
        stored.cmdline
    );
    assert_eq!(
        stored.disk, desc.disk,
        "switch upgrade must preserve the original disk image path"
    );
}

#[test]
#[ignore]
fn e2e_upgrade_boot() {
    let name = unique_name("upgradeboot");
    let _guard = InstanceGuard::new(&name);

    let runtime = provision_and_wait(&name);

    // Record the boot_id so we can confirm the VM actually rebooted.
    let out = ssh_exec(&runtime, "cat /proc/sys/kernel/random/boot_id");
    assert!(
        out.success(),
        "pre-upgrade boot_id read failed (exit {}): {}",
        out.status,
        out.stderr
    );
    let pre_boot_id = out.stdout.trim().to_string();
    assert!(
        !pre_boot_id.is_empty(),
        "pre-upgrade boot_id should not be empty"
    );

    // Invoke `epi upgrade --mode boot` via the CLI binary so we exercise the
    // real command flow (which must NOT call switch-to-configuration).
    // Override XDG_CONFIG_HOME to an empty dir so the user's host-side hooks
    // don't run during the test.
    let empty_xdg = TempDir::new().expect("tempdir failed");
    let xdg_str = empty_xdg.path().to_string_lossy().into_owned();
    let out = process::run_with_env(
        env!("CARGO_BIN_EXE_epi"),
        &["upgrade", &name, "--mode", "boot"],
        &[("XDG_CONFIG_HOME", &xdg_str)],
    )
    .expect("epi upgrade --mode boot failed to spawn");
    assert!(
        out.success(),
        "epi upgrade --mode boot failed (exit {}): {}\n{}",
        out.status,
        out.stderr,
        out.stdout
    );

    // After upgrade, the runtime is fresh — load it and SSH in.
    let runtime2 = instance_store::find_runtime(&name)
        .expect("find_runtime failed")
        .expect("instance should have a runtime after upgrade --mode boot");

    let out = ssh_exec(&runtime2, "cat /proc/sys/kernel/random/boot_id");
    assert!(
        out.success(),
        "post-upgrade boot_id read failed (exit {}): {}",
        out.status,
        out.stderr
    );
    let post_boot_id = out.stdout.trim().to_string();
    assert_ne!(
        pre_boot_id, post_boot_id,
        "VM should have rebooted (boot_id should change after upgrade --mode boot)"
    );
}

#[test]
#[ignore]
fn e2e_mount_home_ownership() {
    let name = unique_name("mntowner");
    let _guard = InstanceGuard::new(&name);

    // Create a nested mount dir under the host $HOME. On macOS the host home
    // (/Users/<user>) differs from the guest home (/home/<user>), so epi-init
    // mounts at the real host path and bind-mounts it into the guest home.
    let home = std::env::var("HOME").expect("HOME not set");
    let user = ssh_user();
    let test_dir = format!("{home}/.epi-test-{name}");
    let nested_mount = format!("{test_dir}/a/b");
    fs::create_dir_all(&nested_mount).unwrap();
    fs::write(format!("{nested_mount}/marker.txt"), "home-mount").unwrap();

    // Ensure cleanup of host directory
    struct CleanupGuard(String);
    impl Drop for CleanupGuard {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = CleanupGuard(test_dir.clone());

    let mounts = vec![nested_mount.clone()];
    let mut resolved = default_resolved();
    resolved.mounts = mounts;

    let runtime = provision_and_wait_with(&name, resolved);

    // The real mount is reachable at the host path inside the guest.
    let cat_cmd = format!("cat {nested_mount}/marker.txt");
    let out = ssh_exec(&runtime, &cat_cmd);
    assert!(
        out.success(),
        "cat marker at host path failed: {}",
        out.stderr
    );
    assert_eq!(out.stdout, "home-mount");

    // The same content is bind-mounted into the guest home, at the path
    // produced by swapping the host home prefix for the guest home.
    let rel = test_dir.strip_prefix(&home).expect("test_dir under home");
    let guest_test_dir = format!("/home/{user}{rel}");
    let guest_nested = format!("{guest_test_dir}/a/b");
    let cat_cmd = format!("cat {guest_nested}/marker.txt");
    let out = ssh_exec(&runtime, &cat_cmd);
    assert!(
        out.success(),
        "cat marker at guest home path failed: {}",
        out.stderr
    );
    assert_eq!(out.stdout, "home-mount");

    // Intermediate directories of the guest-home bind target are created by
    // the user, not root. The bind target sits at a/b, so check a/ and the
    // guest test_dir root — these are plain directories, not mount points.
    let guest_a = format!("{guest_test_dir}/a");
    for dir in [&guest_a, &guest_test_dir] {
        let stat_cmd = format!("stat -c '%U' {dir}");
        let out = ssh_exec(&runtime, &stat_cmd);
        assert!(out.success(), "stat {dir} failed: {}", out.stderr);
        assert_eq!(
            out.stdout, user,
            "directory {dir} should be owned by {user}, got {}",
            out.stdout
        );
    }
}

#[test]
#[ignore]
fn e2e_mount_explicit_dst_skips_home_remap() {
    let name = unique_name("mountdsthome");
    let _guard = InstanceGuard::new(&name);

    let home = std::env::var("HOME").expect("HOME not set");
    let user = ssh_user();
    let test_dir = format!("{home}/.epi-test-{name}");
    fs::create_dir_all(&test_dir).unwrap();
    fs::write(format!("{test_dir}/marker.txt"), "explicit-dst-home").unwrap();

    struct CleanupGuard(String);
    impl Drop for CleanupGuard {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = CleanupGuard(test_dir.clone());

    let mut resolved = default_resolved();
    resolved.mounts = vec![format!("{test_dir}:/workspace")];

    let runtime = provision_and_wait_with(&name, resolved);

    let out = ssh_exec(&runtime, "cat /workspace/marker.txt");
    assert!(
        out.success(),
        "cat marker at explicit dst failed (exit {}): {}",
        out.status,
        out.stderr
    );
    assert_eq!(out.stdout, "explicit-dst-home");

    // The home-remap bind must not fire when dst is explicit: nothing is
    // bind-mounted at the guest-home-equivalent path.
    let rel = test_dir.strip_prefix(&home).expect("test_dir under home");
    let guest_home_path = format!("/home/{user}{rel}");
    let cat_cmd = format!("cat {guest_home_path}/marker.txt");
    let out = ssh_exec(&runtime, &cat_cmd);
    assert!(
        !out.success(),
        "marker should not be reachable at the guest-home-equivalent path when dst is explicit"
    );
}

fn save_stopped_state(name: &str) {
    instance_store::save_state(
        name,
        &instance_store::InstanceState {
            target: e2e_target(),
            runtime: None,
            mounts: vec![],
            project_dir: None,
            disk_size: "40G".to_string(),
            cpus: 1,
            memory_mib: 1024,
            port_specs: vec![],
            ssh_extra_config: vec![],
            descriptor: None,
        },
    )
    .expect("save_state failed");
}

/// No VM required: a stopped instance with no TTY must refuse to connect and
/// point the user at `epi start` / `--start` rather than starting silently.
#[test]
fn ssh_stopped_without_tty_suggests_start() {
    let name = unique_name("sshstopped");
    let _guard = InstanceGuard::new(&name);
    save_stopped_state(&name);

    let out =
        process::run(env!("CARGO_BIN_EXE_epi"), &["ssh", &name]).expect("epi ssh failed to spawn");

    assert!(
        !out.success(),
        "epi ssh on a stopped instance without a TTY should fail, got success:\n{}",
        out.stdout
    );
    assert!(
        out.stderr.contains("stopped"),
        "stderr should report the instance is stopped, got: {}",
        out.stderr
    );
    assert!(
        out.stderr.contains("--start"),
        "stderr should suggest --start, got: {}",
        out.stderr
    );
}

/// `--start` boots a stopped instance non-interactively, then runs the command.
#[test]
#[ignore]
fn e2e_exec_start_flag_boots_stopped() {
    let name = unique_name("execstart");
    let _guard = InstanceGuard::new(&name);

    // Launch through the CLI so a real descriptor is recorded, then stop it.
    let empty_xdg = TempDir::new().expect("tempdir failed");
    let xdg_str = empty_xdg.path().to_string_lossy().into_owned();
    let out = process::run_with_env(
        env!("CARGO_BIN_EXE_epi"),
        &["launch", &name, "--target", &e2e_target()],
        &[("XDG_CONFIG_HOME", &xdg_str)],
    )
    .expect("epi launch failed to spawn");
    assert!(
        out.success(),
        "epi launch failed (exit {}): {}\n{}",
        out.status,
        out.stderr,
        out.stdout
    );

    epi::backend::stop_instance(&name, false).expect("stop failed");
    assert!(
        instance_store::find_runtime(&name)
            .expect("find_runtime failed")
            .is_none(),
        "instance should have no runtime after stop"
    );

    // `epi exec --start` must boot it and run the command.
    let out = process::run_with_env(
        env!("CARGO_BIN_EXE_epi"),
        &["exec", &name, "--start", "--", "echo", "hello"],
        &[("XDG_CONFIG_HOME", &xdg_str)],
    )
    .expect("epi exec --start failed to spawn");
    assert!(
        out.success(),
        "epi exec --start failed (exit {}): {}\n{}",
        out.status,
        out.stderr,
        out.stdout
    );
    assert!(
        out.stdout.contains("hello"),
        "remote command output should contain 'hello', got: {}",
        out.stdout
    );
    assert!(
        epi::backend::instance_is_running(&name).expect("instance_is_running failed"),
        "instance should be running after exec --start"
    );
}
