## Why

Helper cleanup currently uses `ExecStopPost` with manual `systemctl --user stop` commands on the VM service. This causes a deadlock when the instance slice is stopped: the `ExecStopPost` command tries to stop a helper that's already being torn down by the slice, blocking until timeout.

## What Changes

- Add `PartOf=<vm-unit>.service` to each helper unit (passt, virtiofsd) at creation time, so systemd automatically stops helpers when the VM unit stops
- Remove `ExecStopPost` helper cleanup from the VM service — no longer needed since `PartOf=` handles it
- Remove `systemctl_bin()` usage from `cloud_hypervisor::service_properties()` since it no longer generates systemctl commands

## Capabilities

### New Capabilities

_(none)_

### Modified Capabilities

- `systemd-process-lifecycle`: VM exit cascades to helpers via `PartOf=` directive instead of `ExecStopPost` commands

## Impact

- `src/process.rs`: `run_helper` accepts optional VM unit name for `PartOf=` property
- `src/cloud_hypervisor.rs`: `service_properties` drops ExecStopPost generation
- `src/vm_launch.rs`: passes VM unit name to helper startup functions
- No new dependencies, no CLI changes
