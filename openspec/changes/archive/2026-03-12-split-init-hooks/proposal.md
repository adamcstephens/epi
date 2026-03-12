## Why

Guest-init hooks that need networking (e.g., package installation, database seeding, API calls) fail because `epi-init` runs before the network is up. The service only orders itself after `local-fs.target`, so hooks execute without connectivity. Splitting hook execution into a separate systemd service lets core init (user, SSH, mounts) stay fast while hooks get proper network availability.

## What Changes

- Extract guest hook execution from `epi-init.service` into a new `epi-init-hooks.service` that orders after `network-online.target`
- `epi-init.service` continues to handle core setup: mount epidata, read epi.json, create user, set hostname, configure SSH keys, mount virtiofs
- `epi-init-hooks.service` runs guest-init hooks (both seed ISO file-based and Nix-declared) after network is available
- The first-boot guard (`/var/lib/epi-init-done`) moves to or is checked by the hooks service since that's what it guards
- `epi-init-hooks.service` orders after `epi-init.service` to ensure user account and mounts exist before hooks run
- SSH startup (`sshd.service`) continues to depend on `epi-init.service` only — it does NOT wait for hooks

## Capabilities

### New Capabilities
- `guest-init-hooks-service`: Systemd service definition and behavior for the separated `epi-init-hooks.service` that runs guest hooks after network is available

### Modified Capabilities
- `epi-init-service`: Remove hook execution from epi-init; it now only handles core guest initialization
- `guest-init-hooks`: Update execution context — hooks now run in a separate service after network, not inline in epi-init

## Impact

- **NixOS module** (`nix/nixos/epi.nix`): New systemd service definition, modified epi-init script to remove hook execution
- **No host-side changes**: Seed ISO generation, hook discovery, and host lifecycle hooks are unaffected
- **No breaking changes**: Hook authoring interface (file locations, naming, permissions) stays the same
- **Behavioral change**: Hooks now run after network is up, which is the desired fix. SSH becomes available before hooks complete (already the case for post-launch hooks on the host side)
