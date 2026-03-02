## Context

`epi up` currently performs multiple setup stages (target resolution/build, launch input validation, and cloud-hypervisor start), but user-facing output is sparse between command start and completion/failure. For targets that trigger Nix builds, this can look like a stalled command even when progress is occurring. Existing specs already define provisioning semantics and stage-specific error clarity, so this change should add visibility without changing command contract or introducing verbose logs.

## Goals / Non-Goals

**Goals:**
- Surface deterministic setup stage progress messages during `epi up` so users can tell what phase is running.
- Keep output concise and human-readable (stage transitions, not streaming debug output).
- Preserve current provisioning outcomes, persisted state behavior, and error semantics.

**Non-Goals:**
- Adding a new interactive progress UI, spinner framework, or machine-readable event stream.
- Changing target evaluation semantics or cloud-hypervisor launch mechanics.
- Expanding this visibility pattern to other lifecycle commands in this change.

## Decisions

- Emit stage boundary messages from the existing `epi up` orchestration path at key milestones: start target evaluation, target evaluation complete, start launch preparation, launch preparation complete, start VM launch, VM launch complete.
  - Rationale: boundary events are enough to prove liveness without overwhelming output.
  - Alternative considered: line-by-line sub-step logging from internals. Rejected as too verbose and unstable for user-facing CLI output.
- Keep messages in the default CLI output path and align wording with existing actionable error style.
  - Rationale: users should not need extra flags for basic visibility into long-running setup.
  - Alternative considered: gate progress behind a `--verbose` mode. Rejected because the problem exists in normal usage.
- Keep progress reporting best-effort and non-blocking: message emission failures must not alter provisioning behavior.
  - Rationale: visibility should not become a new failure mode.

## Risks / Trade-offs

- [Output assertions in tests become brittle if message wording drifts] -> Mitigation: centralize message strings and assert stable stage tokens/phrasing.
- [Extra lines may be noisy for very fast targets] -> Mitigation: limit output to major stage transitions only.
- [Future refactors may add setup paths that miss stage hooks] -> Mitigation: place hooks in shared orchestration boundaries and cover with integration tests.

## Migration Plan

1. Add stage progress emission in the `epi up` orchestration flow at major boundaries.
2. Update integration/output tests to assert stage visibility for slow/normal provisioning paths.
3. Validate manual runs against a target that triggers a non-trivial Nix build to confirm perceived liveness improves.
4. Rollback strategy: remove or gate progress output hooks while keeping existing provisioning logic untouched.

## Open Questions

- Should successful completion keep the existing final success line unchanged, or should it include a terminal stage marker for consistency?
