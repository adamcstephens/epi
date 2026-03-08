## Context

NixOS disk images are sized to fit their closure. When `epi up` copies a nix-store disk to a writable instance overlay (`disk.img`), the file is the same size as the original image — typically a few hundred MB — leaving almost no headroom. Disk growth requires two cooperating steps:

1. **Host side** — enlarge the raw image file before booting the VM so the block device has the target capacity.
2. **Guest side** — expand the partition table and filesystem at first boot so the OS can use the new space.

`qemu-img resize` handles step 1 cleanly without touching partition metadata. For step 2, cloud-init's built-in `growpart` and `resize_rootfs` modules handle the partition and filesystem expansion on first boot, requiring only that they are listed in the cloud-init module pipeline.

## Goals / Non-Goals

**Goals:**
- Resize the writable disk overlay to a user-specified (or defaulted) size immediately after creation
- Set `boot.growPartition = true` and `fileSystems."/".autoResize = true` in the NixOS guest config so the root partition and filesystem fill the disk on boot
- Expose a `--disk-size` flag on `epi up`; provide a sensible default (40 GiB)
- Report a clear error when `qemu-img` is not on PATH

**Non-Goals:**
- Resizing an already-running or previously-created instance (resize on first creation only)
- Supporting non-ext4 filesystems
- Shrinking disks

## Decisions

### Use `qemu-img resize` for host-side enlargement

`qemu-img resize disk.img <size>` appends sparse zeros to a raw image, making it suitable for enlarging. It is the standard tool for this job and handles both raw and qcow2 formats.

Alternative considered: `truncate -s <size>` works for raw images and requires no extra binary. However, `qemu-img` is already an implicit dependency (cloud-hypervisor ecosystem) and is self-documenting about format support. We use `qemu-img` and locate it via `EPI_QEMU_IMG_BIN` env var with a PATH fallback, matching the pattern used for `virtiofsd` and `pasta`.

### Use `boot.growPartition` + `fileSystems."/".autoResize` for guest-side growth

Partition growth requires two cooperating NixOS options:

- `boot.growPartition = true` — runs `growpart` in early boot to extend the partition entry to fill the block device.
- `fileSystems."/".autoResize = true` — runs `resize2fs` to expand the ext4 filesystem to fill the enlarged partition.

Both must be set; `boot.growPartition` alone leaves the filesystem at its original size. Together they are the NixOS-idiomatic mechanism requiring no cloud-init involvement.

Alternative considered: cloud-init `growpart` + `resize_rootfs` modules. Works but adds cloud-init dependency for something NixOS handles natively. The NixOS options are simpler and more reliable.

### Default disk size: 40 GiB

40 GiB is large enough for typical dev-instance workloads (build outputs, packages, logs) while remaining modest. It can be overridden per-invocation with `--disk-size`.

### Resize only on first creation, not on subsequent `epi up`

The overlay already exists on subsequent runs. Resizing an existing disk that may have live partition data is unsafe without explicit user intent. Skipping resize when `disk.img` already exists (consistent with current `ensure_writable_disk` behavior) is the safe default.

## Risks / Trade-offs

- **`qemu-img` not on PATH** → Mitigation: fail with a clear error message and suggest `EPI_QEMU_IMG_BIN` or installing `qemu-utils`, same pattern as `virtiofsd`.
- **cloud-init growpart not running on re-provisioned instances** → Acceptable: the disk is already at the correct size from the first provisioning; growpart is idempotent.
- **Sparse file on non-`tmpfs` / non-`ext4` host filesystems** → `qemu-img resize` produces a sparse file on supporting filesystems; no action needed.
- **User specifies a size smaller than the source image** → `qemu-img resize` will reject this; we surface the error as-is.
