## 1. Systemd process spawning

- [x] 1.1 Add `escape_unit_name` to `Process` that runs `systemd-escape <instance-name>` and returns the escaped string for use in unit names
- [x] 1.2 Add `generate_unit_id` to `Process` that generates a short random hex string (8 chars) for use as a session ID in unit names
- [x] 1.3 Add `run_helper` to `Process` that invokes `systemd-run --user --collect --unit=<name> --slice=<slice> --property=StandardOutput=file:<path> --property=StandardError=file:<path> --setenv=... -- <prog> <args>` and returns success/failure (changed from `run_scope` to `run_helper` since scopes don't support StandardOutput property)
- [x] 1.4 Add `run_service` to `Process` that invokes `systemd-run --user --collect --unit=<name> --slice=<slice> --property=Type=exec --property=StandardOutput=file:<path> --property=StandardError=file:<path> --property=ExecStopPost=<command> --setenv=... -- <prog> <args>` and returns success/failure. The ExecStopPost command uses `/run/current-system/sw/bin/systemctl` (NixOS absolute path)
- [x] 1.5 Add `unit_is_active` to `Process` that runs `systemctl --user is-active <unit>` and returns bool
- [x] 1.6 Add `stop_unit` to `Process` that runs `systemctl --user stop <unit>` and returns success/failure
- [x] 1.7 Remove `run_detached` and `pid_is_alive` from `Process`

## 2. Instance store changes

- [x] 2.1 Replace `pid`, `passt_pid`, and `virtiofsd_pids` in `Instance_store.runtime` with `unit_id : string`; keep `serial_socket`, `disk`, `ssh_port`, `ssh_key_path`
- [x] 2.2 Update `save_runtime` and `load_runtime` to persist/load `unit_id` instead of PID fields
- [x] 2.3 Remove `reconcile_runtime` function entirely
- [x] 2.4 Remove `kill_if_alive` helper from `Instance_store`
- [x] 2.5 Remove `find_running_owner_by_disk` PID-based logic; replace with systemd unit status check for disk lock conflict detection

## 3. VM launch changes

- [x] 3.1 Update `launch_detached` in `Vm_launch` to use `Process.run_helper` for passt and virtiofsd, and `Process.run_service` for cloud-hypervisor (with `ExecStopPost` that stops the instance slice via `/run/current-system/sw/bin/systemctl --user stop <slice>`)
- [x] 3.2 Generate a `unit_id` per launch and derive unit names: `epi-<escaped>-<id>-vm.service`, `epi-<escaped>-<id>-passt.service`, `epi-<escaped>-<id>-virtiofsd-<i>.service`, all under `epi-<escaped>-<id>.slice`
- [x] 3.3 Before launching, attempt best-effort stop of old slice using old `unit_id` from existing runtime (if present)
- [x] 3.4 Update `launch_detached` return type to include `unit_id` instead of PIDs — return the simplified `Instance_store.runtime`
- [x] 3.5 Add detection and actionable error for systemd user session unavailability (map `systemd-run` failures to `Vm_launch.provision_error`)
- [x] 3.6 Add post-launch liveness check: after `systemd-run` returns success, wait briefly and verify the VM unit is still active to detect immediate failures (exit code, lock conflicts)

## 4. Command handler changes (epi.ml)

- [x] 4.1 Remove all `Instance_store.reconcile_runtime()` calls from command handlers
- [x] 4.2 Replace all `Process.pid_is_alive runtime.pid` checks with `Process.unit_is_active` on the VM service unit name (constructed from escaped instance name + `runtime.unit_id`)
- [x] 4.3 Rewrite `terminate_instance_runtime` to use `Process.stop_unit` on the instance slice instead of SIGTERM+poll+kill children
- [x] 4.4 Remove `kill_if_alive` helper from `Epi`
- [x] 4.5 Remove `pid_is_zombie` function
- [x] 4.6 Update stale-instance handling in `up_command` to stop the old slice (using stored `unit_id`) instead of killing individual PIDs
- [x] 4.7 Update `down_command` to use slice stop
- [x] 4.8 Update `rm_command` to use slice stop for force-termination

## 5. Tests

- [x] 5.1 Update `test_down.ml` — stop assertions verify systemctl stop was called rather than checking PID liveness
- [x] 5.2 Update `test_reconcile.ml` — replaced with placeholder since reconciliation is removed
- [x] 5.3 Update `test_instance_store.ml` unit tests for the new runtime type (`unit_id` instead of PID fields)
- [x] 5.4 Update `test_mount.ml` — replaced PID references with unit_id assertions
- [x] 5.5 Integration tests for `systemctl --user is-active` covered by existing tests that launch real systemd units (console, rm, cache, up stale relaunch tests)
- [x] 5.6 VM exit cascade via ExecStopPost verified through launch failure detection test (launch 3) and stale instance tests
