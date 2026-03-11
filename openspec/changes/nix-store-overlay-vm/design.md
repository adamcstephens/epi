## Context

Currently, `epi launch` provisions a VM by building a full NixOS qcow2 disk image (`config.system.build.images.qemu`) that contains the entire Nix store closure — kernel, system packages, services, everything. This image is then copied from the Nix store into the instance directory as a writable overlay. The process is dominated by image build time and disk copy time, both scaling with the closure size (typically 1-3 GB).

The host already runs virtiofsd for user-requested `--mount` shares. The host's `/nix/store` already contains every store path the guest needs (since the guest image was built from the same flake). cloud-hypervisor supports multiple virtiofs shares.

Nix has an experimental `local-overlay-store` feature that layers a writable upper store on a read-only lower store, managing both the filesystem (via OverlayFS) and the store database (separate upper SQLite DB that references the lower DB).

## Goals / Non-Goals

**Goals:**
- Eliminate the full qcow2 image build from the provisioning path
- Enable `nix build` inside the guest to reuse host store paths without re-downloading or re-building
- Maintain the same user-facing behavior: SSH access, virtiofs mounts, guest hooks, epi-init all work as before
- Keep the guest's writable store layer persistent across reboots

**Non-Goals:**
- Supporting mixed-architecture host/guest (already not supported)
- Sharing the host store with non-NixOS guests
- Making the guest's Nix store survive instance deletion (upper layer lives on the instance disk)
- Garbage collection coordination between host and guest stores

## Decisions

### 0. `epi.overlayStore.enable` toggle — opt-in, traditional path preserved

The entire overlay setup is gated behind `epi.overlayStore.enable` (default `false`). When disabled, the NixOS module produces the traditional full qcow2 image with GRUB, and epi behaves exactly as before. When enabled, the module configures the initrd overlayfs, `local-overlay-store`, `image.repart` minimal disk, and disables the bootloader.

The NixOS module exports `epi.overlayStore` as a boolean in the descriptor JSON (alongside `kernel`, `disk`, `cpus`, etc.). The OCaml `Target.descriptor` type gains an `overlay_store : bool` field. `vm_launch.ml` reads this to decide whether to start the nix-store virtiofsd.

This keeps the traditional path as the safe default while `local-overlay-store` is experimental, and makes the overlay mode opt-in per target configuration.

### 1. Share host `/nix` via virtiofs (not 9p, not NFS)

virtiofsd is already a dependency and the infrastructure for launching it exists in `vm_launch.ml`. virtiofs gives near-native performance for metadata-heavy workloads like Nix store access. 9p has known performance issues with large directory trees. NFS would add a network dependency.

The host's entire `/nix` directory is shared (not just `/nix/store`) because `local-overlay-store` needs access to both the store directory and the store database at `/nix/var/nix/db/`.

### 2. OverlayFS setup in initrd via `postMountCommands`

The overlayfs must be mounted before NixOS stage-2 init runs (since `init` itself lives in `/nix/store`). NixOS provides `boot.initrd.postMountCommands` which runs after the root filesystem is mounted but before `switch_root`. This is the standard hook for early filesystem setup.

Alternative considered: a custom initrd script. Rejected because `postMountCommands` is the supported NixOS mechanism and avoids reimplementing initrd logic.

### 3. `local-overlay-store` for the guest Nix daemon

The guest's nix.conf configures:
```
store = local-overlay://?lower-store=local://?root=/mnt/host&upper-layer=/nix/.store-upper
```

The lower store is the virtiofs-mounted host `/nix`, rooted at `/mnt/host` so Nix finds the store at `/mnt/host/nix/store` and the DB at `/mnt/host/nix/var/nix/db`. The upper layer directory matches the overlayfs upperdir.

This means `nix build` inside the guest sees all host store paths as already present and only builds/fetches what's missing.

### 4. Minimal disk image via `image.repart` with no store closure

Use NixOS's `image.repart` (systemd-repart based) to produce a minimal disk image. The module must be explicitly imported via `${modulesPath}/image/repart.nix`. The image contains a single ext4 root partition with only the directory skeleton needed for the overlayfs setup — no store paths, no boot partition, no bootloader.

```nix
{ modulesPath, ... }:
{
  imports = [ "${modulesPath}/image/repart.nix" ];

  image.repart = {
  sectorSize = 512;
  partitions = {
    "10-root" = {
      contents = {
        "/nix/.store-upper/.keep".source = emptyFile;
        "/nix/.store-work/.keep".source = emptyFile;
        "/mnt/host/nix/.keep".source = emptyFile;
      };
      repartConfig = {
        Type = "root";
        Format = "ext4";
        Label = "nixos";
        Minimize = "guess";
      };
    };
  };
};
```

No `storePaths` — the NixOS system and all packages are accessed through the overlayfs at boot time. No boot partition — cloud-hypervisor receives kernel + initrd directly, so GRUB is unnecessary. The bootloader is disabled entirely (`boot.loader.grub.enable = false`).

Alternative considered: no disk image at all (tmpfs root). Rejected because the upper layer needs to persist across reboots and the guest needs writable `/var`, `/etc`, etc.

### 5. Conditional `/nix` virtiofsd — driven by descriptor

The `/nix` share is an implementation detail, not a user-facing mount. When the descriptor's `overlay_store` field is `true`, `launch_detached` starts a virtiofsd for `/nix` using the tag `nix-store` (distinct from user mounts tagged `hostfs-N`). When `overlay_store` is `false`, no nix-store virtiofsd is started and virtiofsd is only required if `--mount` flags are used (preserving current behavior). The `/nix` share does not appear in the instance's `mounts` file. `epi start` re-reads the descriptor to determine whether to start the nix-store virtiofsd.

### 6. Boot flow

1. cloud-hypervisor receives kernel + initrd directly (existing behavior, unchanged)
2. Initrd mounts root partition from disk
3. `postMountCommands`: mount virtiofs `nix-store` at `/mnt-root/mnt/host/nix`, then overlayfs at `/mnt-root/nix/store`
4. `switch_root` to the merged root — `init` is now accessible via overlayfs
5. NixOS stage-2 boots normally; Nix daemon uses `local-overlay-store`
6. `epi-init.service` runs as before (hostname, user, SSH keys, user-mounts, hooks)

## Risks / Trade-offs

- **`local-overlay-store` is experimental** → Pin to a known-working Nix version in the guest. The feature has been in Nix since 2.19 and the core mechanism (OverlayFS + split DB) is straightforward. Mitigate by having integration tests that exercise `nix build` inside the guest.

- **Host store GC breaks the guest** → If the host garbage-collects a store path that the guest's lower layer references, the guest will see broken symlinks/missing paths. Mitigation: document that host GC should not run while overlay VMs are active. A future enhancement could use `nix-store --add-root` on the host for the guest's system closure.

- **First boot needs system profile bootstrap** → The guest's `/nix/var/nix/profiles/system` must point to the correct system closure. Since this path is in `/nix/var/nix/` (not `/nix/store/`), it's on the root partition, not in the overlay. The minimal image builder or `epi-init` must set this up. Alternatively, the kernel cmdline `init=` path directly references the store path, bypassing the profile symlink.

- **Nested store URL syntax is fragile** → The `lower-store=local://?root=/mnt/host` query parameter inside another query string requires careful URL encoding. Test this configuration carefully.

- **Bootloader disabled** → With `boot.loader.grub.enable = false`, NixOS may raise assertions about no bootloader being configured. May need to suppress the assertion since cloud-hypervisor handles kernel/initrd loading directly.
