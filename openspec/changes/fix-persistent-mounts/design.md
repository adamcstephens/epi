## Context

Two separate bugs prevent mounts from working on second and subsequent boots:

1. **Guest bug**: Cloud-init writes virtiofs systemd mount units to `/run/systemd/system/`, which is an in-memory tmpfs cleared on every reboot. Cloud-init only runs on first boot, so the units are never recreated. `/etc/systemd/system/` is read-only in NixOS (managed by activation scripts).

2. **Host bug**: The `start` command calls `Vm_launch.provision ~mount_paths:[]`, so virtiofsd processes are never restarted when an instance is resumed after the VM stops.

## Goals / Non-Goals

**Goals:**
- Mounts work on first boot and every subsequent boot.
- `epi start` re-launches virtiofsd with the original mount paths.
- The NixOS module change is generic: it reads mount config at runtime from the seed ISO, not from baked-in configuration.
- Single source of truth for mount paths in the guest: the seed ISO.

**Non-Goals:**
- Changing mount paths after an instance is launched.
- Supporting mount changes without reprovisioning.

## Decisions

**Add `epi-mounts` to the seed ISO**

The cloud-init seed ISO (`cidata.iso`) already lives in the instance state directory on the host and is attached to the VM on every boot. It has a well-known block device label (`cidata`). Adding a plain text file (`epi-mounts`, one path per line) to the ISO alongside `user-data` and `meta-data` makes the mount configuration available to the guest on every boot without relying on cloud-init to run.

This eliminates the need for a writable `/var/lib/epi/mounts` file inside the guest, and removes all mount-related logic from cloud-init user-data.

**NixOS systemd generator reads from the cidata block device**

A systemd generator baked into the NixOS image:
1. Finds the block device labeled `cidata` (via `/dev/disk/by-label/cidata`)
2. Mounts it read-only to a temporary directory
3. Reads `epi-mounts` (if present)
4. Emits a `.mount` unit per path into the generator output directory (`$1`, i.e. `/run/systemd/system/`)
5. Each unit includes `ExecStartPre=/bin/mkdir -p <path>` to ensure the mount point exists
6. Unmounts the temporary directory

Generators run after udev has settled block devices, so `/dev/disk/by-label/cidata` is available. The generator is a no-op if `epi-mounts` is absent or empty (instances without mounts).

The NixOS change is generic: it contains no hardcoded paths — all configuration comes from the ISO at runtime.

**Host-side: plain `mounts` file in instance state directory**

When `launch` runs with `--mount` paths, write those paths to `~/.local/state/epi/<instance>/mounts` (one per line) alongside the existing `runtime` and `target` files. The `start` command reads this file and passes the paths to `Vm_launch.provision` to restart virtiofsd.

This is simpler than parsing the ISO on the host (avoids needing `isoinfo` or mounting a loop device). Both files are written from the same data at launch time; they stay in sync naturally.

**Remove mount logic from cloud-init user-data**

With the generator handling unit creation and `mkdir -p`, cloud-init no longer needs to write files or run commands for mounts. The `generate_user_data` function drops the `write_files` and `runcmd` blocks for mounts entirely. This simplifies the code and removes a source of first-boot-only fragility.

## Risks / Trade-offs

- [Risk] If the `cidata` block device is not present or not labeled correctly, the generator silently emits nothing. → The seed ISO is always attached (same as before this change); label is set by genisoimage at creation. Low risk.
- [Risk] Temporary mount in the generator adds a small boot-time dependency on the block subsystem being settled. → Generators run after udev, so block devices are available. Standard NixOS practice.
- [Risk] Host `mounts` file and guest `epi-mounts` in ISO can drift if someone edits one manually. → Both are written together at launch and treated as read-only after that. Acceptable for current scope.

## Migration Plan

Existing instances provisioned before this fix have neither `epi-mounts` in their ISO nor a host-side `mounts` file. They must be reprovisioned (`epi rm` + `epi launch`) to get persistent mounts — same as before, since mounts were already broken on second boot.
