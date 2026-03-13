## Why

The VM service's ExecStop commands use bare binary names (`ch-remote`, `timeout`, `tail`) which systemd cannot find — `--setenv` only applies to `ExecStart`, not `ExecStop`. This causes graceful shutdown to fail silently, and the VM is killed immediately instead of receiving an ACPI power button signal for clean guest shutdown.

## What Changes

- Generate a shutdown script (`shutdown.sh`) in the instance directory at launch time, with absolute paths to all binaries baked in
- Replace three separate `ExecStop` property lines with a single `ExecStop=<instance-dir>/shutdown.sh`
- The script performs the same sequence: power-button → wait for exit → shutdown-vmm fallback

## Capabilities

### New Capabilities

### Modified Capabilities
- `vm-api-socket`: ExecStop mechanism changes from three inline commands to a single generated shutdown script. Behavioral requirements (power-button, wait, shutdown-vmm fallback) remain the same.

## Impact

- `src/cloud_hypervisor.rs`: `service_properties()` takes script path instead of generating ExecStop commands directly
- `src/vm_launch.rs`: generates shutdown script at launch, resolves binary paths
- `src/process.rs`: may need `find_executable` made public
