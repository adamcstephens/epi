## Why

Cloud-hypervisor knowledge is scattered across `vm_launch.rs`: binary path resolution, CLI argument construction, and (with the upcoming graceful shutdown change) API socket management and ch-remote invocations. Extracting a dedicated module isolates this hypervisor-specific concern and keeps `vm_launch.rs` focused on orchestrating the launch flow.

## What Changes

- Create `src/cloud_hypervisor.rs` module owning all cloud-hypervisor and ch-remote concerns
- Move CH argument building out of `vm_launch.rs` into the new module
- Move CH binary path resolution (`EPI_CLOUD_HYPERVISOR_BIN`) into the new module
- Add ch-remote binary path resolution (`EPI_CH_REMOTE_BIN`) in the new module
- Add API socket path derivation and ExecStop property generation for graceful shutdown
- `vm_launch.rs` delegates to the new module for CH-specific logic

## Capabilities

### New Capabilities

_(none — this is a refactor that moves existing behavior into a new module boundary)_

### Modified Capabilities

_(none — no spec-level behavior changes, only internal code organization)_

## Impact

- New file: `src/cloud_hypervisor.rs`
- Modified: `src/vm_launch.rs` (removes CH arg building, delegates to new module)
- Modified: `src/main.rs` (adds `mod cloud_hypervisor`)
- No behavior changes, no API changes, no dependency changes
