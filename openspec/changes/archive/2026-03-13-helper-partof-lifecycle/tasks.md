## 1. Add PartOf= to helper units

- [x] 1.1 Update `process::run_helper` to accept an optional VM unit name and add `--property=PartOf=<vm-unit>` when provided
- [x] 1.2 Pass the VM unit name from `vm_launch.rs` when starting passt and virtiofsd helpers

## 2. Remove ExecStopPost from VM service

- [x] 2.1 Remove ExecStopPost generation from `cloud_hypervisor::service_properties()`, keep only After= ordering
- [x] 2.2 Remove `systemctl_bin()` usage from `cloud_hypervisor.rs` if no longer needed

## 3. Test

- [x] 3.1 Run `just test` to verify unit and CLI tests pass
- [x] 3.2 Add e2e test for clean shutdown: after `stop_instance`, verify VM unit, helper units, and slice are all inactive
- [x] 3.3 Add e2e test for unclean shutdown: kill the VM process directly, verify helper units are stopped via `PartOf=` (slice may linger)
- [x] 3.4 Run all e2e tests
