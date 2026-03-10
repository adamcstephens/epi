## Why

Cloud-init adds unnecessary complexity and ordering constraints to VM initialization. It runs once at first boot (so mount units it creates don't persist across reboots), and its execution timing relative to systemd generators is implicit rather than explicit. We already work around cloud-init's limitations with a custom systemd generator for mounts. Replacing cloud-init entirely with our own init service gives us full control over boot ordering — user creation happens before mounts, hostname is set deterministically, and there's one unified path for all guest-side initialization.

## What Changes

- Remove cloud-init from the NixOS guest configuration
- Replace the `cidata` ISO with an `epidata` ISO containing a single `epi.json` file that combines user provisioning data and mount paths
- Add an `epi-init` systemd service that runs early in boot and handles all initialization:
  - Waits for and mounts the `epidata` ISO
  - Reads `epi.json` to create the user (with SSH keys, UID, groups, sudo), set hostname, and mount virtiofs filesystems
- Remove the existing `epi-mounts-generator` systemd generator (its responsibilities move into epi-init)
- Host-side: generate `epi.json` (JSON) instead of separate `user-data` (cloud-config YAML), `meta-data`, and `epi-mounts` files

## Capabilities

### New Capabilities
- `epi-init-service`: A NixOS systemd service that replaces cloud-init and the epi-mounts generator, handling user provisioning, hostname, and virtiofs mounts in a single ordered sequence

### Modified Capabilities
- `vm-user-provisioning`: User creation moves from cloud-init to epi-init; the seed ISO changes from `cidata` with cloud-config YAML to `epidata` with a single `epi.json`
- `virtiofs-mount`: Mount unit generation moves from a systemd generator to epi-init service, with explicit ordering after user creation; mount paths move from separate `epi-mounts` file into `epi.json`

## Impact

- **NixOS guest config** (`nix/nixos/epi.nix`): Remove cloud-init enable, remove epi-mounts-generator, add epi-init service, update block device label from `cidata` to `epidata`
- **Host-side OCaml** (`lib/vm_launch.ml`): Replace `generate_user_data`, `generate_meta_data`, and `epi-mounts` file creation with a single `epi.json` generation; change ISO volume label from `cidata` to `epidata`; rename staging dir and ISO file
- **Tests** (`test/test_seed.ml`): Update to verify `epi.json` format instead of cloud-config YAML
- **Boot time**: Should decrease — cloud-init is heavyweight; a focused shell script is faster
- **Dependencies**: `cloud-init` package removed from guest closure, reducing image size
