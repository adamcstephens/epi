## Why

The `systemd-run` calls in `run_helper` and `run_service` forward the entire user environment via `--setenv`. This leaks the user's shell environment into the transient systemd units (cloud-hypervisor, passt, virtiofsd), which is unnecessary and can cause subtle issues — processes may behave differently depending on the invoking shell's state, and sensitive env vars (tokens, credentials) get propagated into long-running services.

## What Changes

- Remove the blanket `std::env::vars()` forwarding from both `run_helper` and `run_service`
- Forward only the specific env vars that the spawned processes actually need (e.g., `PATH` for binary resolution)

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `systemd-process-lifecycle`: The requirement for environment forwarding changes from "forward all" to "forward only explicitly needed variables"

## Impact

- `src/process.rs`: `run_helper` and `run_service` functions
- All transient systemd units (cloud-hypervisor, passt, virtiofsd) will run with a minimal environment instead of inheriting the user's full shell env
