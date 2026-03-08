## Why

NixOS disk images built by Nix are tightly sized to the closure, leaving little or no free space in the instance's writable overlay. Without disk growth, VMs quickly run out of space during normal use (packages, logs, build artefacts). Growth needs to happen at two points: when the overlay is created (so the block device is large enough), and at first boot (so the partition and filesystem fill the available space).

## What Changes

- `epi up` gains an optional `--disk-size` flag (e.g. `--disk-size 40G`) that sets the target size of the writable disk overlay; a built-in default (40 GiB) is used when the flag is omitted
- After copying the Nix-store disk to the instance overlay, `epi` resizes the image file to the requested size using `qemu-img resize`
- The NixOS guest configuration sets `boot.growPartition = true` and `fileSystems."/".autoResize = true` so the root partition and ext4 filesystem are expanded to fill the disk on boot

## Capabilities

### New Capabilities
- `vm-disk-resize`: Overlay disk resizing at instance creation time and automatic partition/filesystem growth at first guest boot via cloud-init

### Modified Capabilities
- `nixos-manual-test-config`: Add `boot.growPartition = true` and `fileSystems."/".autoResize = true` to the manual-test configuration so the partition and filesystem grow to fill the resized disk on boot

## Impact

- `lib/vm_launch.ml`: `ensure_writable_disk` gains a resize step after the copy; new error variant for resize failure; `up` subcommand gains `--disk-size` argument
- NixOS module (`nixos/`): `boot.growPartition = true` added to the guest configuration
- `qemu-img` must be available at runtime (new external dependency); error path if binary is absent
