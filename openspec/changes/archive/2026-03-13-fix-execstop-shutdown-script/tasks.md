## 1. Make binary resolution available

- [x] 1.1 Make `process::find_executable` public so it can be used from `vm_launch`

## 2. Generate shutdown script at launch

- [x] 2.1 Add a function to resolve required binaries (`ch-remote`, `timeout`, `tail`) and generate the shutdown script content with absolute paths
- [x] 2.2 Write the shutdown script to `<instance-dir>/shutdown.sh` with executable permissions during launch, before starting the VM service
- [x] 2.3 Fail launch with a clear error if any required binary is not found in PATH

## 3. Update ExecStop to use the script

- [x] 3.1 Update `cloud_hypervisor::service_properties()` to accept the shutdown script path and emit a single `ExecStop=<script-path>` instead of three inline commands
- [x] 3.2 Update the call site in `vm_launch.rs` to pass the script path

## 4. Tests

- [x] 4.1 Add a unit test for shutdown script generation (correct content, absolute paths)
- [x] 4.2 Update existing `service_properties` tests to reflect the new single-ExecStop signature
- [x] 4.3 Run e2e tests to verify graceful shutdown works end-to-end
