---
# epi-qh4q
title: mounts in home can create parents owned by root
status: completed
type: bug
priority: normal
created_at: 2026-03-16T00:45:42Z
updated_at: 2026-04-18T03:18:24Z
---

When mounting paths under ~, intermediate directories may be created owned by root instead of the user. Needs careful investigation of the mount/mkdir flow.


## Summary of Changes

**Root cause:** The `epi-init` systemd service runs as root. When creating mount point directories with `mkdir -p` for paths under the user's home directory, all intermediate directories were created with `root:root` ownership.

**Fix (nix/nixos/epi.nix):**
- Added `pkgs.getent` to `runtimeInputs` so `getent` is available in the init script
- Before creating mount directories, resolve the user's home via `getent passwd`
- For mount paths under the user's home, run `mkdir -p` as the user via `su -` instead of as root
- Non-home mount paths continue to use `mkdir -p` as root (unchanged behavior)

**Test (tests/e2e.rs):**
- Added `e2e_mount_home_ownership` test that mounts a nested path under `$HOME` and verifies intermediate directories are owned by the user, not root
