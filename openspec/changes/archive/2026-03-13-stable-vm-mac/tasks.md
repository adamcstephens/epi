## 1. Failing E2E Test

- [x] 1.1 Add `e2e_stop_start_ssh` test that launches a VM, verifies SSH, stops it, starts it, and verifies SSH again — assert it fails with current code

## 2. Core Implementation

- [x] 2.1 Add `generate_mac` function to `vm_launch.rs` that hashes the instance name to produce a `02:xx:xx:xx:xx:xx` MAC
- [x] 2.2 Add `mac` parameter to `cloud_hypervisor::build_args` and include it in the `--net` argument
- [x] 2.3 Call `generate_mac` in `launch_vm_inner` and pass the result to `build_args`

## 3. Verification

- [x] 3.1 Run the new e2e test and verify it passes
- [x] 3.2 Run full e2e test suite to check for regressions
