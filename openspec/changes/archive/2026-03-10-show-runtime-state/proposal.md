## Why

The `epi list` and `epi status` commands don't show whether instances are actually running. A user with multiple instances has no way to see at a glance which are up and which are stopped without running `status` on each one individually. Adding runtime state (running/stopped, SSH port) to these commands gives immediate visibility into the fleet.

## What Changes

- `epi list` gains a `STATUS` column showing `running` or `stopped` for each instance, and an `SSH` column showing the forwarded port (or `-` when stopped)
- `epi status` gains structured output showing running/stopped state, SSH port, serial socket path, disk path, and unit ID when available
- Instance liveness is checked via systemd unit status for each listed instance

## Capabilities

### New Capabilities

_None — this change enhances existing capabilities._

### Modified Capabilities

- `dev-instance-cli`: The `list` command output adds STATUS and SSH columns; the `status` command output becomes more structured with runtime details

## Impact

- `lib/epi.ml`: Modified — list and status command implementations
- `lib/instance_store.ml` or `lib/process.ml`: May need to expose batch runtime checks
- `test/`: Updated test expectations for new output format
- **No breaking changes** — output format changes are additive (new columns/fields)
