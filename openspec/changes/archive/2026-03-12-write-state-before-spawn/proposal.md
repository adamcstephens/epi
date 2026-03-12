## Why

Killing `epi launch` mid-flight (or any crash between VM spawn and state write) leaves a running VM with no state file, making it invisible to `epi list` and impossible to clean up via `epi rm`. The VM, passt, and virtiofsd processes continue running as orphaned systemd user services.

## What Changes

- Write instance state to disk **before** spawning any systemd processes, so there is always a record to clean up against
- Introduce a lifecycle phase (e.g. `launching`) in state that distinguishes in-progress launches from fully provisioned instances
- Ensure `epi rm` and `epi list` can discover and clean up instances that were mid-launch when interrupted
- On successful provision completion, update state to the current `provisioned` form (with full runtime metadata)

## Capabilities

### New Capabilities

- `atomic-launch-state`: Write state before spawning processes and update it on completion, ensuring interrupted launches are always discoverable and cleanable

### Modified Capabilities

_None_ — the instance-state-storage spec's file format gains a new lifecycle representation, but this is captured by the new capability above.

## Impact

- `lib/vm_launch.ml` — state write moved earlier in the launch sequence
- `lib/instance_store.ml` — new function to write pre-launch state; possible new `phase` or partial-runtime representation in `state.json`
- `lib/epi.ml` — `epi rm` and `epi list` must handle instances in the launching phase (stop slice if unit_id is known, clean up state)
- `state.json` format — gains a way to represent "launching but not yet provisioned" (backward-compatible: existing files without the new field are treated as provisioned)
