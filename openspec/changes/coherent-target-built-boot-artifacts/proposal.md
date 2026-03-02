## Why

`epi up --target .#manual-test` can boot with a kernel/initrd resolved from the target while reusing an out-of-band mutable disk image (`/home/adam/projects/epi/nixos.img`). This can produce non-coherent boot tuples and fail during stage1->stage2 handoff, so provisioning needs a single target-built artifact set.

## What Changes

- Require `epi up` NixOS launch descriptors to resolve kernel, initrd, and disk from the same target evaluation output.
- Disallow fallback to pre-existing local mutable disk images when target outputs do not provide a coherent disk artifact.
- Add clear pre-launch validation and actionable errors when a target cannot provide a coherent bootable artifact set.
- Update manual-test wiring/docs to reflect target-built disk sourcing for VM launches.

## Capabilities

### New Capabilities
None.

### Modified Capabilities
- `vm-provision-from-target`: tighten provisioning requirements so launch artifacts are coherent and target-built as one set.
- `nixos-manual-test-config`: align manual-test configuration expectations with target-built boot artifacts used by `epi up`.

## Impact

- Affected code: `lib/vm_launch.ml`, target descriptor resolution path, and Nix module wiring in `nix/nixos/manual-test.nix`.
- Affected behavior: `epi up` for NixOS targets fails fast when coherent disk artifacts are missing instead of booting mismatched tuples.
- API/CLI surface: no new command flags; stricter validation and clearer failure messages.
