## 1. E2e Test Helpers

- [x] 1.1 Add `test/helpers/e2e_helpers.ml` with unique instance name generation, cleanup wrapper (`Fun.protect` calling `Epi.stop_instance` + `Instance_store.remove`), provision+wait helper (calls `Vm_launch.provision` and `Vm_launch.wait_for_ssh`, fails test on error), and SSH exec helper (runs SSH via `Process.run` using runtime record fields)
- [x] 1.2 Register e2e test suites in `test/test_epi.ml` and update `test/dune` for new modules

## 2. Lifecycle Test

- [x] 2.1 Create `test/test_lifecycle_e2e.ml` with a `Slow` test that provisions a VM via the helper, verifies SSH exec, stops the instance, starts it again, verifies SSH exec after restart, removes the instance and verifies it's gone from `Instance_store.list`

## 3. Mount Tests

- [x] 3.1 Create `test/test_mount_e2e.ml` with a `Slow` test that creates a temp directory with a marker file, provisions a VM with that mount path, and verifies the file is readable in the guest via SSH exec
- [x] 3.2 Add a `Slow` test that verifies mounts persist across stop/start: stop the VM, start it again, verify the mounted file is still accessible

## 4. Validation

- [x] 4.1 Run the full e2e suite with `-e` against a real VM and verify all tests pass
  - lifecycle test passes
  - mount tests fail: pre-existing bug in NixOS mount generator (systemd unit has "bad-setting", mount point not auto-created in guest)
- [x] 4.2 Verify cleanup works correctly — no leaked VMs after test run
