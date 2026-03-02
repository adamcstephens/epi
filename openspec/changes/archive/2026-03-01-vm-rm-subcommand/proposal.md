## Why

Virtual machines currently lack a dedicated command to reclaim resources when they are no longer needed. Operators have to stop the VM before removing it, and the workflow is manual and error-prone, especially when automation is expected.

## What Changes

- Introduce `rm` as a first-class subcommand under the VM CLI so users can delete VMs directly.
- Add a `-f/--force` flag that will terminate the VM if it is running before deleting it, preventing premature failures.
- Document the new command, its flags, and guardrails so operators understand the exact behavior.

## Capabilities

### New Capabilities
- `vm-rm`: Remove a VM, optionally forcing shutdown when active.

### Modified Capabilities
- None.

## Impact

- CLI surface under the VM namespace (`vm rm` and related flags).
- VM lifecycle logic for termination and cleanup routines.
- Tests and documentation covering VM removal scenarios.
