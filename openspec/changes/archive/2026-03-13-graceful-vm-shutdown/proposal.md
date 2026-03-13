## Why

`epi rm -f` and `epi stop` hang for 90 seconds when a VM is running because cloud-hypervisor does not respond to SIGTERM. Systemd waits the full `DefaultTimeoutStopSec` (90s) before escalating to SIGKILL. This makes force-removing or stopping instances unusable in practice.

## What Changes

- Add `--api-socket` to cloud-hypervisor launch arguments, enabling API-based lifecycle control
- Configure VM service `ExecStop` to perform a graceful shutdown sequence: ACPI power-button (guest-clean shutdown), wait for exit, then forceful VMM shutdown
- Add systemd ordering (`After=`) between VM service and helper services so slice stop respects shutdown order
- Add `TimeoutStopSec` on the VM service as a hard safety net

## Capabilities

### New Capabilities
- `vm-api-socket`: Configuring cloud-hypervisor with an API socket and using ch-remote for graceful shutdown
- `vm-stop-ordering`: Systemd unit ordering between VM and helper services within the instance slice

### Modified Capabilities
- `systemd-process-lifecycle`: VM service gains ExecStop commands (graceful shutdown sequence), After= ordering relative to helpers, and TimeoutStopSec. Slice stop now respects unit ordering instead of killing all processes simultaneously.

## Impact

- `src/process.rs`: `run_service` accepts additional systemd properties from caller
- `src/vm_launch.rs`: Adds API socket to CH args, builds ExecStop/After/TimeoutStopSec properties, stop_instance simplified to just stopping the slice
- No new dependencies (ch-remote ships in the same nix package as cloud-hypervisor)
- No API or CLI changes
