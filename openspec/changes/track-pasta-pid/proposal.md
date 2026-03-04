## Why

When `epi up` launches a VM, it starts a passt process for userspace networking but immediately discards its PID. This means pasta processes are never explicitly cleaned up — they accumulate across VM restarts, linger after `epi down`, and are invisible to `reconcile_runtime`.

## What Changes

- `Instance_store.runtime` gains a `pasta_pid` field alongside the existing `pid` (cloud-hypervisor PID)
- `epi up` terminates any tracked pasta process for the instance before starting a new one
- `epi down` terminates the pasta process alongside cloud-hypervisor
- `reconcile_runtime` kills and clears pasta processes for stale instances
- State file format updated to persist `pasta_pid`

## Capabilities

### New Capabilities

_(none)_

### Modified Capabilities

- `vm-runtime-state-reconciliation`: Reconciliation now tracks and cleans up the pasta PID alongside the hypervisor PID. Stale instance cleanup terminates the pasta process. The stored runtime metadata includes `pasta_pid`.
- `vm-provision-from-target`: `epi up` terminates any existing pasta process for the instance before launching a replacement, preventing accumulation on repeated up calls.

## Impact

- `lib/instance_store.ml`: `runtime` type gains `pasta_pid : int option`; state file serialization and parsing updated
- `lib/vm_launch.ml`: `launch_detached` stores the pasta pid; instance cleanup helpers kill it
- `bin/` (down/up command handlers): pass-through of pasta pid cleanup
- State file format: backward-compatible (existing rows without pasta_pid field parse as `pasta_pid = None`)
