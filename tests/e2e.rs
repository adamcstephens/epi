//! E2E tests that launch real VMs.
//!
//! These require a working nix flake target and systemd user session.
//! Run with: cargo test --test e2e
//!
//! The target is read from EPI_E2E_TARGET (default: '.#manual-test').

use epi::{config, hooks, instance_store, process, ssh, target, vm_launch};
use std::fs;
use std::sync::LazyLock;
use tempfile::TempDir;

fn e2e_target() -> String {
    std::env::var("EPI_E2E_TARGET").unwrap_or_else(|_| ".#manual-test".to_string())
}

static DESCRIPTOR: LazyLock<(String, target::Descriptor)> = LazyLock::new(|| {
    let t = e2e_target();
    eprintln!("Generating descriptor");
    let desc = target::resolve_descriptor(&t).expect("failed to resolve e2e target");
    target::validate_descriptor(&desc).expect("invalid e2e descriptor");
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
        let _ = vm_launch::stop_instance(&self.name);
        let _ = instance_store::remove(&self.name);
    }
}

fn default_resolved() -> config::Resolved {
    let (target_str, _) = &*DESCRIPTOR;
    config::Resolved {
        target: target_str.clone(),
        mounts: vec![],
        disk_size: "40G".to_string(),
        cpus: None,
        memory: None,
        default_name: "default".to_string(),
        ports: vec![],
    }
}

fn provision_and_wait(name: &str) -> instance_store::Runtime {
    provision_and_wait_with(name, default_resolved())
}

fn provision_and_wait_with(name: &str, resolved: config::Resolved) -> instance_store::Runtime {
    instance_store::save_state(
        name,
        &instance_store::InstanceState {
            target: resolved.target.clone(),
            runtime: None,
            mounts: instance_store::canonicalize_mounts(&resolved.mounts),
            project_dir: None,
            disk_size: Some(resolved.disk_size.clone()),
        },
    )
    .expect("save_state failed");

    let runtime = vm_launch::provision(&vm_launch::ProvisionParams {
        instance_name: name,
        target_str: &resolved.target,
        mounts: &resolved.mounts,
        disk_size: &resolved.disk_size,
        rebuild: false,
        cpus_override: resolved.cpus,
        memory_override: resolved.memory,
        port_specs: &resolved.ports,
    })
    .expect("provision failed");

    instance_store::set_provisioned(name, runtime.clone()).expect("set_provisioned failed");

    let ssh_port = runtime.ssh_port.expect("no ssh port");
    ssh::generate_config(
        &ssh::config_path(name),
        name,
        ssh_port,
        &ssh::user(),
        std::path::Path::new(&runtime.ssh_key_path),
        None,
    )
    .expect("generate ssh config failed");
    ssh::wait_for_ssh(&ssh::config_path(name), name, 120).expect("ssh wait failed");

    runtime
}

fn ssh_user() -> String {
    std::env::var("USER").unwrap_or_else(|_| "epi".to_string())
}

fn ssh_exec(runtime: &instance_store::Runtime, cmd: &str) -> process::Output {
    let port = runtime.ssh_port.unwrap().to_string();
    let user_host = format!("{}@127.0.0.1", ssh_user());
    process::run(
        "ssh",
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

#[test]
#[ignore] // requires real VM — run explicitly
fn e2e_lifecycle() {
    let name = unique_name("lifecycle");
    let _guard = InstanceGuard::new(&name);

    // Provision with a port mapping (:8080 = auto-allocate host, guest 8080)
    let mut resolved = default_resolved();
    resolved.ports = vec![":8080".to_string()];
    let runtime = provision_and_wait_with(&name, resolved.clone());
    assert!(runtime.ssh_port.is_some());

    // Verify port mapping was stored in runtime
    assert_eq!(runtime.ports.len(), 1, "expected 1 port mapping");
    assert_eq!(runtime.ports[0].guest, 8080);
    assert!(runtime.ports[0].host > 0, "host port should be allocated");
    assert_eq!(runtime.ports[0].protocol, "tcp");

    // Verify port mapping persisted to state
    let loaded = instance_store::find_runtime(&name).unwrap().unwrap();
    assert_eq!(loaded.ports.len(), 1);
    assert_eq!(loaded.ports[0].guest, 8080);

    // Verify passt was started with the additional port forwarding arg
    let unit_id = &runtime.unit_id;
    let passt_unit = format!("epi-{name}_{unit_id}_passt.service");
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
    assert!(instance_store::instance_is_running(&name).unwrap());

    // Stop
    vm_launch::stop_instance(&name).expect("stop failed");

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
    vm_launch::stop_instance(&name).expect("stop failed");
    instance_store::remove(&name).expect("remove failed");
    assert!(instance_store::find(&name).unwrap().is_none());
}

#[test]
#[ignore]
fn e2e_ssh_config_trusted_after_launch() {
    let name = unique_name("sshcfg");
    let _guard = InstanceGuard::new(&name);

    let runtime = provision_and_wait(&name);
    let ssh_port = runtime.ssh_port.expect("no ssh port");

    // Record host key and rewrite config
    ssh::trust_host_key(
        &name,
        ssh_port,
        &ssh::user(),
        std::path::Path::new(&runtime.ssh_key_path),
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
    let out = process::run("ssh", &["-F", &config_str, &name, "echo", "trusted"]).unwrap();
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

    // Create two temp dirs with distinct markers to test multiple mounts
    let mount_dir_a = TempDir::new().unwrap();
    fs::write(mount_dir_a.path().join("marker.txt"), "mount-a").unwrap();
    let mount_path_a = mount_dir_a.path().to_string_lossy().to_string();

    let mount_dir_b = TempDir::new().unwrap();
    fs::write(mount_dir_b.path().join("marker.txt"), "mount-b").unwrap();
    let mount_path_b = mount_dir_b.path().to_string_lossy().to_string();

    let mounts = vec![mount_path_a.clone(), mount_path_b.clone()];

    instance_store::save_state(
        &name,
        &instance_store::InstanceState {
            target: target_str.to_string(),
            runtime: None,
            mounts: instance_store::canonicalize_mounts(&mounts),
            project_dir: None,
            disk_size: Some("40G".into()),
        },
    )
    .unwrap();

    let runtime = vm_launch::provision(&vm_launch::ProvisionParams {
        instance_name: &name,
        target_str,
        mounts: &mounts,
        disk_size: "40G",
        rebuild: false,
        cpus_override: None,
        memory_override: None,
        port_specs: &[],
    })
    .expect("provision failed");

    instance_store::set_provisioned(&name, runtime.clone()).unwrap();

    let ssh_port = runtime.ssh_port.expect("no ssh port");
    ssh::generate_config(
        &ssh::config_path(&name),
        &name,
        ssh_port,
        &ssh::user(),
        std::path::Path::new(&runtime.ssh_key_path),
        None,
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

    let ssh_port = runtime.ssh_port.unwrap();
    let env = hooks::HookEnv {
        instance_name: name.clone(),
        ssh_port,
        ssh_key_path: runtime.ssh_key_path.clone(),
        ssh_user: "root".to_string(),
        state_dir: instance_store::state_dir().to_string_lossy().to_string(),
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
    assert!(instance_store::instance_is_running(&name).unwrap());

    // Verify API socket exists
    let inst_dir = instance_store::instance_dir(&name);
    let api_socket = inst_dir.join("api.sock");
    assert!(api_socket.exists(), "api.sock should exist after launch");

    // Stop and measure time — should complete well under 90s
    let start = std::time::Instant::now();
    vm_launch::stop_instance(&name).expect("stop failed");
    let elapsed = start.elapsed();

    assert!(
        elapsed.as_secs() < 30,
        "stop took {}s, expected < 30s (graceful shutdown should be fast)",
        elapsed.as_secs()
    );

    assert!(!instance_store::instance_is_running(&name).unwrap());
}

#[test]
#[ignore]
fn e2e_clean_shutdown_stops_helpers() {
    let name = unique_name("cleanstop");
    let _guard = InstanceGuard::new(&name);

    let runtime = provision_and_wait(&name);
    let unit_id = &runtime.unit_id;

    // Construct expected unit names
    let vm_unit = instance_store::vm_unit_name(&name, unit_id).unwrap();
    let passt_unit = format!("epi-{name}_{unit_id}_passt.service");
    let slice = instance_store::slice_name(&name, unit_id).unwrap();

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
    vm_launch::stop_instance(&name).expect("stop failed");

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
    vm_launch::stop_instance(&name).expect("stop failed");

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

#[test]
#[ignore]
fn e2e_no_env_leak() {
    let name = unique_name("noenv");
    let _guard = InstanceGuard::new(&name);

    // Set a sentinel env var that should NOT appear in the systemd units
    let sentinel = "EPI_TEST_SENTINEL";
    unsafe { std::env::set_var(sentinel, "leaked") };

    let runtime = provision_and_wait(&name);
    let unit_id = &runtime.unit_id;

    let vm_unit = instance_store::vm_unit_name(&name, unit_id).unwrap();
    let passt_unit = format!("epi-{name}_{unit_id}_passt.service");

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

#[test]
#[ignore]
fn e2e_vm_crash_stops_helpers() {
    let name = unique_name("vmcrash");
    let _guard = InstanceGuard::new(&name);

    let runtime = provision_and_wait(&name);
    let unit_id = &runtime.unit_id;

    let vm_unit = instance_store::vm_unit_name(&name, unit_id).unwrap();
    let passt_unit = format!("epi-{name}_{unit_id}_passt.service");

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

#[test]
#[ignore]
fn e2e_cp_file_to_vm() {
    let name = unique_name("cp");
    let _guard = InstanceGuard::new(&name);

    let runtime = provision_and_wait(&name);
    let ssh_port = runtime.ssh_port.unwrap();

    // Create a temp file to copy
    let tmp_dir = TempDir::new().unwrap();
    let src_file = tmp_dir.path().join("test-cp.txt");
    fs::write(&src_file, "epi-cp-test-content").unwrap();

    // Build rsync command matching cmd_cp's logic
    let ssh_cmd = format!(
        "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i {} -p {}",
        runtime.ssh_key_path, ssh_port
    );
    let remote_dest = format!("{}@127.0.0.1:/tmp/test-cp.txt", ssh_user());

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
    resolved.memory = Some(2048);

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
#[ignore] // cloud-hypervisor crashes with boot>1 + vhost-user passt: https://github.com/cloud-hypervisor/cloud-hypervisor/issues/7766
fn e2e_cpus_override() {
    let name = unique_name("cpuover");
    let _guard = InstanceGuard::new(&name);

    let mut resolved = default_resolved();
    resolved.cpus = Some(2);

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
