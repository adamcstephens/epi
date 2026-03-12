//! E2E tests that launch real VMs.
//!
//! These require a working nix flake target and systemd user session.
//! Run with: cargo test --test e2e -- --test-threads=1
//!
//! The target is read from EPI_E2E_TARGET (default: '.#manual-test').

use epi::{console, hooks, instance_store, process, target, vm_launch};
use std::fs;
use tempfile::TempDir;

fn e2e_target() -> String {
    std::env::var("EPI_E2E_TARGET").unwrap_or_else(|_| ".#manual-test".to_string())
}

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
        let _ = vm_launch::stop_instance(&self.name);
        let _ = instance_store::remove(&self.name);
    }
}

fn provision_and_wait(name: &str, target_str: &str) -> instance_store::Runtime {
    let desc = target::resolve_descriptor(target_str).expect("failed to resolve target");
    target::validate_descriptor(&desc).expect("invalid descriptor");
    target::ensure_paths_exist(&desc).expect("paths missing");

    instance_store::set_launching(name, target_str, vec![]).expect("set_launching failed");

    let runtime =
        vm_launch::provision(name, target_str, &[], "40G", false).expect("provision failed");

    instance_store::set_provisioned(name, runtime.clone()).expect("set_provisioned failed");

    let ssh_port = runtime.ssh_port.expect("no ssh port");
    vm_launch::wait_for_ssh(ssh_port, &runtime.ssh_key_path, 120).expect("ssh wait failed");

    runtime
}

fn ssh_exec(runtime: &instance_store::Runtime, cmd: &str) -> process::Output {
    let port = runtime.ssh_port.unwrap().to_string();
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
            "root@127.0.0.1",
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
    let target_str = e2e_target();

    // Provision
    let runtime = provision_and_wait(&name, &target_str);
    assert!(runtime.ssh_port.is_some());

    // Verify SSH works
    let out = ssh_exec(&runtime, "echo hello");
    assert!(out.success());
    assert_eq!(out.stdout, "hello");

    // Verify hostname
    let out = ssh_exec(&runtime, "hostname");
    assert!(out.success());

    // Verify instance is running
    assert!(instance_store::instance_is_running(&name).unwrap());

    // Stop
    vm_launch::stop_instance(&name).expect("stop failed");

    // Verify runtime cleared
    assert!(instance_store::find_runtime(&name).unwrap().is_none());
    // Target still exists
    assert!(instance_store::find(&name).unwrap().is_some());

    // Restart
    let runtime2 = provision_and_wait(&name, &target_str);
    let out = ssh_exec(&runtime2, "echo back");
    assert!(out.success());
    assert_eq!(out.stdout, "back");

    // Remove
    vm_launch::stop_instance(&name).expect("stop failed");
    instance_store::remove(&name).expect("remove failed");
    assert!(instance_store::find(&name).unwrap().is_none());
}

#[test]
#[ignore]
fn e2e_console_log_captured() {
    let name = unique_name("console");
    let _guard = InstanceGuard::new(&name);
    let target_str = e2e_target();

    let _runtime = provision_and_wait(&name, &target_str);

    // Start console capture
    console::start_capture(&name).expect("start_capture failed");

    // Give it a moment to capture some output
    std::thread::sleep(std::time::Duration::from_secs(2));

    // Check that console.log exists
    let log_path = instance_store::console_log_path(&name);
    assert!(log_path.exists(), "console.log should exist");

    let content = fs::read_to_string(&log_path).unwrap_or_default();
    // Console log should have some kernel output
    assert!(!content.is_empty(), "console.log should not be empty");
}

#[test]
#[ignore]
fn e2e_mount() {
    let name = unique_name("mount");
    let _guard = InstanceGuard::new(&name);
    let target_str = e2e_target();

    // Create a temp dir with a marker file to mount
    let mount_dir = TempDir::new().unwrap();
    fs::write(mount_dir.path().join("marker.txt"), "epi-mount-test").unwrap();

    let desc = target::resolve_descriptor(&target_str).expect("resolve failed");
    target::validate_descriptor(&desc).unwrap();
    target::ensure_paths_exist(&desc).unwrap();

    let mount_path = mount_dir.path().to_string_lossy().to_string();
    let mounts = vec![mount_path.clone()];

    instance_store::set_launching(&name, &target_str, mounts.clone()).unwrap();

    let runtime =
        vm_launch::provision(&name, &target_str, &mounts, "40G", false).expect("provision failed");

    instance_store::set_provisioned(&name, runtime.clone()).unwrap();

    let ssh_port = runtime.ssh_port.expect("no ssh port");
    vm_launch::wait_for_ssh(ssh_port, &runtime.ssh_key_path, 120).expect("ssh wait failed");

    // Check the mounted file is readable in the guest
    // virtiofsd mounts appear under /mnt/hostfs-N or similar depending on guest config
    let out = ssh_exec(&runtime, "cat /mnt/hostfs-0/marker.txt");
    if out.success() {
        assert_eq!(out.stdout, "epi-mount-test");
    } else {
        // Mount point might differ — try finding it
        let find_out = ssh_exec(&runtime, "find / -name marker.txt 2>/dev/null");
        panic!(
            "could not read mounted marker.txt. find output: {}",
            find_out.stdout
        );
    }
}

#[test]
#[ignore]
fn e2e_hooks() {
    let name = unique_name("hooks");
    let _guard = InstanceGuard::new(&name);
    let target_str = e2e_target();

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

    let runtime = provision_and_wait(&name, &target_str);

    // Run post-launch hooks manually
    let desc = target::resolve_descriptor(&target_str).unwrap();
    let hook_scripts = hooks::discover(&name, &desc.hooks.post_launch, "post-launch").unwrap();

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
