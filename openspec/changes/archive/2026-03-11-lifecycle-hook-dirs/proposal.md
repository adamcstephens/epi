## Why

Users need a way to run custom scripts at key points in the VM lifecycle — both on the host (e.g., after launch, before stop) and inside the guest (e.g., during init). There is currently no extension mechanism for this.

## What Changes

- Add drop-in script directories as the hook mechanism, discovered at three layers: user-level (`~/.config/epi/hooks/`), project-level (`.epi/hooks/`), and per-instance (subdirectory named after the instance)
- Host hooks: scripts in `<hook-point>.d/` directories are executed on the host at lifecycle events (e.g., `post-launch.d/`, `pre-stop.d/`)
- Guest hooks: scripts in `guest-init.d/` are embedded into the seed ISO and executed by `epi-init` as the provisioned user
- Execution order: user-wide → project-wide → instance-specific, lexically sorted within each layer
- Environment variables are injected so scripts can reference instance details (`EPI_INSTANCE`, `EPI_SSH_PORT`, etc.)

## Capabilities

### New Capabilities
- `host-lifecycle-hooks`: Drop-in script directories for host-side lifecycle events, with three-layer discovery and environment variable injection
- `guest-init-hooks`: Drop-in script directories for guest-side initialization, embedded in seed ISO and executed as the provisioned user

### Modified Capabilities
- `epi-init-service`: Must execute guest hook scripts after existing init steps
- `vm-provision-from-target`: Must collect and embed guest hook scripts into the seed ISO

## Impact

- `lib/vm_launch.ml`: Hook discovery, collection, and host-side execution at lifecycle points
- `lib/hooks.ml` (new): Hook directory resolution and script execution logic
- `nix/nixos/epi.nix`: Execute guest hook scripts from seed ISO as provisioned user
- `lib/seed.ml` or equivalent: Embed guest hook scripts into seed ISO
- Tests for hook discovery, ordering, and execution at each layer
