---
# epi-azk6
title: add upgrade capability
status: completed
type: task
priority: normal
created_at: 2026-03-16T03:19:57Z
updated_at: 2026-03-21T20:20:49Z
---

## Command

`epi upgrade <instance> [--mode boot]`

## Modes

### `switch` (default)
1. Re-evaluate flake target → new descriptor
2. Build kernel + initrd + toplevel (skip disk image)
3. `nix copy` new toplevel closure to guest
4. Run `switch-to-configuration switch` on guest (live activation)
5. Update state.json descriptor (kernel/initrd/cmdline) for next boot
6. Update gcroots
7. VM stays running

### `boot` (`--mode boot`)
1. Re-evaluate flake target → new descriptor
2. Build kernel + initrd + toplevel (skip disk image)
3. `nix copy` new toplevel closure to guest
4. Run `switch-to-configuration boot` on guest (register for next boot)
5. Pre-stop hooks
6. Stop VM
7. Start VM with new kernel/initrd/cmdline
8. Post-launch hooks
9. Update state.json descriptor
10. Update gcroots

## Design Notes

### Copying toplevel into guest
`NIX_SSHOPTS="-F <ssh_config>" nix copy --to ssh://<instance> <toplevel>`

Reuses the instance's existing SSH config. Runs `nix-store --serve --write` on the guest, handles closure diffing automatically (only sends missing paths). Verified working — no special guest-side config needed.

### Artifacts
Only build kernel + initrd + toplevel. Skip disk image build (~3 min savings). The existing qcow2 overlay is preserved.

### Hooks
Treated same as stop/start: pre-stop before stopping, post-launch after restart (boot mode only). Switch mode does not trigger lifecycle hooks.

### State update
Update `descriptor` in state.json with new kernel/initrd/cmdline from the re-evaluated descriptor. Keep existing `disk` path (overlay unchanged). Update gcroots to point to new kernel/initrd store paths.

## Summary of Changes

### New command: `epi upgrade <instance> [--mode boot]`

**Switch mode** (default): Re-evaluates the flake target, builds the system toplevel (skipping disk image), copies the closure to the guest via `nix copy`, and runs `switch-to-configuration switch` for live activation. VM stays running.

**Boot mode**: Same as switch but runs `switch-to-configuration boot`, then stops and restarts the VM with the new kernel/initrd/cmdline from the updated descriptor, including pre-stop/post-launch hooks.

### Key implementation details
- `target::build_toplevel()` builds the system toplevel and returns its store path
- `target::upgrade_artifacts()` returns kernel + initrd artifacts (no disk image)
- `ssh::nix_copy_closure()` copies a nix store closure to a running instance
- `ssh::run_on_guest()` executes a command on an instance via SSH
- `instance_store::update_descriptor()` updates just the descriptor in state.json
- Preserves the original disk path in the descriptor during upgrade (overlay is unchanged)
- GC roots are created before state update to avoid corrupted state on failure
- NixOS epi module adds `@wheel` to `trusted-users` so `nix copy` works without signature issues
