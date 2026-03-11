## 1. NixOS Module: overlayStore toggle

- [x] 1.1 Add `epi.overlayStore.enable` option (default `false`) to `nix/nixos/epi.nix`
- [x] 1.2 Export `overlayStore = cfg.overlayStore.enable;` in the `config.epi` attribute set
- [x] 1.3 Gate all overlay-specific config (initrd, local-overlay-store, image.repart, bootloader disable) behind `lib.mkIf cfg.overlayStore.enable`
- [x] 1.4 When `overlayStore` is disabled, preserve existing behavior: full image via `image.repart` with store closure (switched from qcow2 to repart for both modes)
- [x] 1.5 Enable `epi.overlayStore.enable = true` in the `overlay-test` nixosConfiguration in `flake.nix`

## 2. NixOS Guest Configuration (overlay mode)

- [x] 2.1 Add `overlay` to `boot.initrd.availableKernelModules`
- [x] 2.2 Add `boot.initrd.postMountCommands` that mounts virtiofs `nix-store` at `/mnt-root/mnt/host/nix` (read-only) and sets up overlayfs at `/mnt-root/nix/store` with upper/work dirs on the root partition
- [x] 2.3 Configure `nix.settings` with `local-overlay-store` experimental feature and `store = "local-overlay://..."` pointing to the virtiofs-mounted host store as lower and `/nix/.store-upper` as upper layer
- [x] 2.4 Disable the bootloader (`boot.loader.grub.enable = false`) — both modes use direct kernel boot via cloud-hypervisor

## 3. Minimal Disk Image via image.repart (overlay mode)

- [x] 3.1 Import `${modulesPath}/image/repart.nix` and configure `image.repart` with a single ext4 root partition (label `nixos`, `Minimize = "guess"`), no `storePaths`, and `contents` that creates the directory skeleton: `/nix/.store-upper`, `/nix/.store-work`, `/mnt/host/nix`
- [x] 3.2 Update `config.epi.disk` to point to the repart image output (both modes now use repart)
- [ ] 3.3 Verify the minimal image builds and is under 100 MB

## 4. OCaml Descriptor Changes

- [x] 4.1 Add `overlay_store : bool` field to `Target.descriptor` type in `lib/target.ml`
- [x] 4.2 Parse `overlayStore` from JSON in `descriptor_of_json` (default `false` for backward compatibility)
- [x] 4.3 Serialize `overlayStore` in `descriptor_to_json`

## 5. Host-Side virtiofsd for /nix

- [x] 5.1 In `vm_launch.ml`, when `descriptor.overlay_store` is `true`, start a virtiofsd daemon for `/nix` (tag `nix-store`, socket `virtiofsd-nix.sock`) during `launch_detached`, before user-mount virtiofsd instances
- [x] 5.2 Pass the `nix-store` virtiofsd socket to cloud-hypervisor as an additional `--fs` argument alongside user mounts
- [x] 5.3 Include the nix-store virtiofsd unit in the systemd slice for cleanup on instance down
- [x] 5.4 When `overlay_store` is `true`, require virtiofsd even when no `--mount` flags are passed
- [x] 5.5 When `overlay_store` is `false`, preserve existing behavior (virtiofsd only required with `--mount`)

## 6. Adjust Existing Provisioning Flow

- [x] 6.1 Update `ensure_writable_disk` to handle the minimal image (still needs copy-on-write overlay)
- [x] 6.2 Ensure `epi start` re-reads the descriptor to determine whether to start the nix-store virtiofsd
- [x] 6.3 Update kernel cmdline if needed — overlay mode uses direct store path `init=${toplevel}/init`; non-overlay uses profile symlink

## 7. Testing

- [ ] 7.1 Build the minimal disk image and verify it contains no `/nix/store` paths
- [ ] 7.2 Launch a VM with `epi launch --target '.#overlay-test'` and verify SSH access works
- [ ] 7.3 Run `nix path-info` inside the guest for a path known to exist on the host — confirm it succeeds
- [ ] 7.4 Run `nix build` inside the guest for a simple derivation — confirm host deps are reused and new output goes to upper layer
- [ ] 7.5 Reboot the guest and verify upper layer store paths persist
- [ ] 7.6 Verify `--mount` user shares still work alongside the automatic `/nix` share
- [ ] 7.7 Launch a VM with `epi launch --target '.#manual-test'` and verify traditional behavior is unchanged
