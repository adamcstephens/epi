## Why

`epi up` can spend noticeable time in Nix evaluation/build and VM launch preparation, but users currently get limited feedback while waiting. This makes normal setup latency look like a hang and increases uncertainty about whether the command is making progress.

## What Changes

- Add explicit, human-readable setup stage progress output to `epi up` for long-running phases (target evaluation/build, launch descriptor preparation, and VM start).
- Keep progress messaging concise and stable, so users can tell what stage is running without noisy logs.
- Preserve current command semantics and error behavior, while aligning success/failure output with the new stage visibility.

## Capabilities

### New Capabilities
- None.

### Modified Capabilities
- `vm-provision-from-target`: extend provisioning behavior to include user-visible setup stage progress during `epi up`.

## Impact

- Affected behavior: `epi up` output during setup/provisioning becomes stage-aware instead of mostly silent.
- Affected code: CLI orchestration and output/reporting around target resolution, descriptor preparation, and VM launch.
- Affected tests: command output/integration tests that assert provisioning messages and stage-specific flows.
