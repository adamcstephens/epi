## Why

Users who define their VM configuration in Nix (`nixosConfigurations`) should be able to declare hook scripts directly in the NixOS module, alongside their other VM settings. Currently hooks can only be provided via file-based drop-in directories (user-level and project-level), which means Nix-native users must manage separate script files outside their flake. Adding NixOS module options for hooks gives a third, declarative layer that integrates naturally with the Nix ecosystem.

## What Changes

- Add `epi.hooks.guest-init` option to the NixOS module as an attrset mapping script names to derivations/paths
- Add `epi.hooks.post-launch` and `epi.hooks.pre-stop` options for host-side hooks
- NixOS-declared hooks are embedded in the target descriptor output (same mechanism as kernel/disk/initrd paths)
- Host-side OCaml hook discovery gains a third layer: nix-config hooks, with lowest precedence (user > project > nix-config)
- Guest-init hooks from NixOS config are embedded in the seed ISO alongside file-based guest hooks, also at lowest precedence

## Capabilities

### New Capabilities
- `nixos-hook-options`: NixOS module options for declaring hooks in the VM configuration, and their integration into host-side discovery and guest-init ISO embedding

### Modified Capabilities
- `host-lifecycle-hooks`: Add nix-config as a third discovery layer with lowest precedence
- `guest-init-hooks`: Add nix-config guest-init hooks as a third source embedded in the seed ISO with lowest precedence

## Impact

- `nix/nixos/epi.nix`: New option declarations and config wiring
- `lib/hooks.ml`: Extended discovery to include nix-config hook paths from target descriptor
- Target descriptor JSON: New optional `hooks` field carrying paths to nix-declared hook scripts
- Seed ISO generation: Include nix-config guest-init hooks
