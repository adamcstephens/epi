## Context

`epi up` currently resolves launch descriptor fields from `target.config.epi.cloudHypervisor` and then starts cloud-hypervisor. The manual-test target wires kernel/initrd from NixOS build outputs, but disk can be a mutable workspace path. This allows non-coherent boot tuples (fresh kernel/initrd + stale external root disk), which can fail during early boot with stage1->stage2 handoff errors.

The change spans descriptor resolution, pre-launch validation, and manual-test target wiring. It does not introduce a new user-facing command, but it tightens correctness guarantees for existing `epi up --target` flows.

## Goals / Non-Goals

**Goals:**
- Ensure launch artifacts (kernel/initrd/disk) for NixOS targets come from one target-built output set.
- Fail fast with actionable errors when a target cannot provide coherent boot artifacts.
- Keep CLI ergonomics unchanged (`epi up` interface stays the same).

**Non-Goals:**
- Adding snapshotting, overlay, or copy-on-write disk lifecycle management.
- Supporting arbitrary external disk images as first-class inputs for the NixOS manual-test path.
- Redesigning runtime state reconciliation or serial-console behavior.

## Decisions

1. **Descriptor contract requires coherent disk provenance for NixOS targets**
   - Decision: treat the disk path as part of the target-built descriptor contract for NixOS boot flows.
   - Rationale: kernel/initrd/disk coherence is a boot correctness property, not an optional optimization.
   - Alternative considered: keep external disk fallback with warnings. Rejected because warnings still permit brittle boots and nondeterministic failures.

2. **Validate coherence before launching cloud-hypervisor**
   - Decision: perform explicit validation that launch inputs are coherent and fail before hypervisor spawn when they are not.
   - Rationale: prevents expensive failed boots and gives users immediate guidance.
   - Alternative considered: launch anyway and parse stage1 output. Rejected because failure appears late and root cause remains indirect.

3. **Manual-test target follows the same artifact coherence model**
   - Decision: update manual-test documentation/configuration to align with target-built disk sourcing rather than a hand-managed mutable workspace image.
   - Rationale: keeps local validation aligned with production behavior of target-derived descriptors.
   - Alternative considered: keep manual-test as an exception. Rejected because exception paths silently become the most-used path during development.

## Risks / Trade-offs

- [Reduced flexibility for ad hoc local images] -> Mitigation: keep the coherent path as default and document explicit custom-target workflows separately if needed.
- [Existing local manual test setups may break] -> Mitigation: provide clear migration notes and targeted error messages that explain what artifact is missing.
- [Nix build time increases when disk artifacts must be produced] -> Mitigation: document caching expectations and keep validation errors deterministic so rebuilds are intentional.

## Migration Plan

1. Update target descriptor requirements/specs to require coherent target-built artifact sets.
2. Update `epi` provisioning validation to reject non-coherent launch inputs before hypervisor launch.
3. Update manual-test configuration/docs to use the coherent target-built disk path.
4. Validate with `epi up --target .#manual-test` and ensure failures point to target-output issues, not stage1 runtime ambiguity.

Rollback strategy: revert descriptor coherence enforcement and manual-test wiring as one change if regressions block local workflows.

## Open Questions

- Should we support an explicit opt-in escape hatch for external mutable disks in non-manual-test targets?
- Which target output shape should be canonical for disk artifacts (direct path field vs. derived from a toplevel image output)?
