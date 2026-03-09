## Why

All existing integration tests use mocked runtimes (fake cloud-hypervisor, virtiofsd, passt, resolver scripts). This means features like mounts, SSH exec, and VM lifecycle are only tested against simulated behavior — bugs in real VM interactions (cloud-init, virtiofs mount generation, SSH connectivity) can only be caught by manual testing with `.#manual-test`. We need automated tests that exercise the full stack with real VMs.

## What Changes

- Add integration tests that call OCaml library functions directly (`Vm_launch.provision`, `Vm_launch.wait_for_ssh`, `Epi.stop_instance`, `Instance_store` operations, etc.) against real VMs
- Tests invoke the library API, not the CLI — no shelling out to the `epi` binary
- Test cases cover:
  - VM lifecycle: provision, verify SSH, stop, start, remove
  - Mounts: provision with mount paths, verify volume is mounted and accessible in guest via SSH exec
- Cleanup uses `Instance_store.remove` and systemd unit stopping directly

## Capabilities

### New Capabilities
- `e2e-test-harness`: Test infrastructure for running integration tests against real VMs using direct OCaml function calls, including setup, teardown, and assertion helpers
- `e2e-mount-verification`: Integration test that provisions a VM with a mount and verifies the volume is properly mounted and readable in the guest

### Modified Capabilities

## Impact

- `test/` — new e2e test files and helpers
- `test/dune` — updated to include new test modules
- CI considerations: e2e tests require real cloud-hypervisor, systemd user session, and nix — they may need to run separately from unit/integration tests
