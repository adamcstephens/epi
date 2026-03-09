## Why

The current process management uses fork+setsid with PID files and signal-0 liveness checks. This leads to stale PID files after crashes, orphaned child processes (passt, virtiofsd) when the VM dies unexpectedly, and a reactive reconciliation loop that must run on every command. Systemd transient units provide cgroup-based process tracking, automatic child cleanup, and native lifecycle queries, eliminating these failure modes.

## What Changes

- Replace `Process.run_detached` (fork+setsid+execvpe) with `systemd-run --user --scope` invocations for cloud-hypervisor, passt, and virtiofsd processes
- Group all processes for an instance under a shared systemd slice (`epi-<instance>.slice`) so `systemctl --user stop epi-<instance>.slice` tears everything down atomically
- Replace PID fields in `Instance_store.runtime` (pid, passt_pid, virtiofsd_pids) with a single instance unit name; metadata like serial_socket, disk, ssh_port, ssh_key_path remain
- Replace `Process.pid_is_alive` (signal-0) checks with `systemctl --user is-active` queries
- **BREAKING**: Remove `reconcile_runtime()` — systemd tracks process liveness natively, so the startup reconciliation pass becomes unnecessary
- Replace `terminate_instance_runtime` SIGTERM+poll logic with `systemctl --user stop` on the instance slice

## Capabilities

### New Capabilities
- `systemd-process-lifecycle`: Defines how epi spawns, queries, and stops processes using systemd transient user units (scopes and slices) instead of direct fork+PID tracking

### Modified Capabilities
- `vm-runtime-state-reconciliation`: Reconciliation requirements change — PID-based liveness checks and cleanup are replaced by systemd unit status queries; the startup reconciliation pass is removed
- `vm-provision-from-target`: Process spawning requirements change — passt, virtiofsd, and cloud-hypervisor are started via systemd-run scopes under an instance slice instead of fork+setsid

## Impact

- **lib/process.ml**: `run_detached` replaced with systemd-run invocation; `pid_is_alive` replaced with systemctl query
- **lib/instance_store.ml**: `runtime` type loses PID fields, gains unit name; `reconcile_runtime` removed; `save_runtime`/`load_runtime` simplified
- **lib/vm_launch.ml**: All `Process.run_detached` call sites changed to use new systemd spawning
- **lib/epi.ml**: `terminate_instance_runtime` uses systemctl stop; all `pid_is_alive` checks replaced; `reconcile_runtime` calls removed
- **Dependencies**: Requires `systemd-run` and `systemctl` on PATH (standard on NixOS/systemd Linux); no new OCaml library dependencies
- **Runtime**: Requires user-level systemd (`--user`); `loginctl enable-linger` needed if VMs should survive user logout
