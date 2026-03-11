## Why

Building a full NixOS qcow2 disk image with the entire Nix store closure baked in is the dominant cost in VM provisioning — often GBs of store paths copied into the image. By sharing the host's `/nix` into the guest via virtiofs and using Nix's `local-overlay-store` experimental feature, we can eliminate the image build entirely, replacing it with a tiny sparse disk that only holds the guest's writable delta.

## What Changes

- New `epi.overlayStore.enable` option in the NixOS module gates the entire overlay setup; when disabled (default), the traditional full-image path is preserved unchanged
- When enabled, the guest initrd mounts the host's Nix store via virtiofs and sets up an overlayfs so `/nix/store` is a merged view of host (lower, read-only) + guest (upper, writable)
- When enabled, the guest Nix daemon uses `local-overlay-store` to see host store paths in its DB, enabling `nix build` inside the VM to skip already-built dependencies
- When enabled, the disk image is a minimal sparse image (via `image.repart`) with just directory skeleton — no store closure, no bootloader
- When disabled, the disk image remains the full qcow2 via `config.system.build.images.qemu` with GRUB
- New `overlayStore` boolean field in the target descriptor; `vm_launch.ml` reads it to decide whether to start a virtiofsd for `/nix`

## Capabilities

### New Capabilities
- `nix-store-overlay`: Host-to-guest Nix store sharing via virtiofs + overlayfs + local-overlay-store, including initrd setup, Nix daemon configuration, and minimal disk image generation

### Modified Capabilities
- `virtiofs-mount`: When descriptor indicates `overlayStore`, an additional virtiofsd instance is started for `/nix`
- `vm-provision-from-target`: New `overlayStore` boolean in the descriptor; when true, the disk is a minimal sparse image and the host starts a nix-store virtiofsd
- `epi-init-service`: The init service must handle the case where `/nix/store` is already an overlayfs mount (no changes to store paths needed, but filesystem assumptions may change)

## Impact

- **nix/nixos/epi.nix**: Major changes — initrd overlayfs setup, `local-overlay-store` Nix config, minimal image builder
- **lib/vm_launch.ml**: Conditionally start virtiofsd for `/nix` based on descriptor's `overlayStore` field
- **lib/target.ml**: Add `overlay_store` field to descriptor type and JSON parsing
- **flake.nix**: May need to expose the minimal image builder
- **Nix dependency**: Requires Nix with `local-overlay-store` experimental feature available inside the guest
- **Host requirement**: virtiofsd must be available (already a dependency for `--mount`)
- **Architecture constraint**: Host and guest must be the same architecture (already true for current targets)
