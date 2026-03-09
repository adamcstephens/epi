## Why

When `--mount` is used, mounts only work on first boot. There are two bugs: the guest loses its mount unit configuration on reboot (cloud-init only runs once and writes to an ephemeral location), and the `start` command never restarts virtiofsd so the backing filesystem isn't present anyway.

## What Changes

- Add an `epi-mounts` plain text file (one path per line) to the cloud-init seed ISO alongside `user-data` and `meta-data`
- Add a NixOS systemd generator to the guest image that reads `epi-mounts` from the `cidata` block device on every boot and emits virtiofs `.mount` units — no cloud-init dependency for mount setup
- Persist mount paths in a plain `mounts` file in the instance host state directory so `start` can restart virtiofsd with the original paths
- Remove mount-related `write_files` and `runcmd` from cloud-init user-data (no longer needed for mount units or mount directories — the generator handles both)

## Capabilities

### New Capabilities

_(none)_

### Modified Capabilities

- `virtiofs-mount`: Implementation changes only. The existing requirement that mounts are available in the guest is unchanged; the fix makes it work beyond first boot. No new user-facing behavior.

## Impact

- `lib/vm_launch.ml`: Add `epi-mounts` file to seed ISO staging; remove mount unit generation from `generate_user_data`; save mount paths to `instance_dir/mounts` at launch
- `lib/instance_store.ml`: Add `save_mounts` / `load_mounts` for the host-side `mounts` file
- `lib/epi.ml`: Pass loaded mount paths to `Vm_launch.provision` in the `start` command
- `nix/nixos/epi.nix`: Add a systemd generator that reads from the `cidata` block device
