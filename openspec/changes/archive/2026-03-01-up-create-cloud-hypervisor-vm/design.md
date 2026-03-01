## Context

`epi up` currently validates `--target`, stores `<instance, target>` in the local state file, and prints a confirmation line. No VM provisioning is attempted, so later lifecycle commands operate on metadata without a backing cloud-hypervisor process. The project already depends on `cloud-hypervisor` in the dev environment, and the CLI contract for instance naming/target syntax is established.

## Goals / Non-Goals

**Goals:**
- Make `epi up` actually provision and start a cloud-hypervisor VM from the selected flake target.
- Keep current CLI input behavior (optional instance name, required target format).
- Ensure state is only persisted when VM provisioning succeeds.
- Provide deterministic, actionable error messages for target resolution and VM launch failures.
- Keep implementation testable by isolating external process execution behind small interfaces.
- Keep VM runtime detached from the `epi up` process while preserving a serial console access path.
- Keep runtime state trustworthy by reconciling tracked PID/lock state at CLI startup.

**Non-Goals:**
- Implement full orchestration for `rebuild`, `down`, `ssh`, `logs`, and `status` beyond what is required to support `up`.
- Introduce remote state management or multi-host scheduling.
- Add long-running daemonization/process supervision beyond the immediate VM launch flow.

## Decisions

### 1. Split `up` into resolver + launcher pipeline
`up` will execute a strict pipeline:
1. Parse and validate target string (existing behavior).
2. Evaluate target into a VM launch descriptor (artifact paths + runtime knobs).
3. Launch cloud-hypervisor with that descriptor.
4. Persist instance mapping only after successful launch.

Rationale: preserves clear failure boundaries and prevents stale instance entries.
Alternative considered: save state first then attempt launch. Rejected because it records nonexistent instances on failure.

### 2. Introduce a typed VM launch descriptor
Add an internal record (for example `Vm_launch.Config`) representing resolved target outputs needed by cloud-hypervisor, such as kernel/rootfs/initrd image path, CPU/memory, and network options.

Rationale: keeps command execution logic separate from target resolution and simplifies unit tests.
Alternative considered: pass raw strings through the CLI layer. Rejected because validation and error reporting become scattered.

### 3. Isolate external process execution
Use a dedicated module for shelling out to target evaluation tooling and cloud-hypervisor invocation.

Rationale: enables deterministic tests by stubbing process execution and keeps `lib/epi.ml` focused on command flow.
Alternative considered: direct `Unix` calls inline in `up_command`. Rejected due to poor testability and harder error handling.

### 4. Standardize user-facing failures by stage
Errors will identify stage and corrective action:
- Target resolution failure: include target and evaluation stderr summary.
- Missing launch artifacts: include which required path is missing.
- cloud-hypervisor launch failure: include exit code and key stderr lines.

Rationale: users can quickly distinguish flake issues from runtime issues.
Alternative considered: generic `up failed` message. Rejected as non-actionable.

### 5. Detached launch plus explicit console attachment
`up` should launch cloud-hypervisor in detached mode and return once startup succeeds. Serial output should be exposed through a stable per-instance endpoint (Unix socket), and a dedicated `epi console [instance]` command should connect to that endpoint.

Rationale: this resolves the tension between long-running background VMs and interactive debugging access.
Alternative considered: always stream serial output in `up`. Rejected because it blocks the command and prevents detached operation.

### 6. Runtime metadata and startup reconciliation
Track per-instance runtime metadata in local state: at minimum cloud-hypervisor PID, serial socket path, and launch disk path. During CLI startup, run a fast reconciliation pass (`kill -0` style process liveness checks and basic metadata sanity) and mark stale runtime entries as stopped before command handling.

Rationale: avoids stale state drift and improves lock conflict diagnostics.
Alternative considered: only detect lock conflicts at launch failure time. Rejected because users get late and less precise feedback.

## Risks / Trade-offs

- [Target output schema drift] -> Mitigation: validate resolved descriptor fields explicitly and fail with a schema mismatch message.
- [External binary assumptions] -> Mitigation: check for cloud-hypervisor availability before launch and emit guidance.
- [Process lifecycle ambiguity if launch detaches] -> Mitigation: define success criteria (process started and returned success contract) and test it.
- [Detached serial endpoint unavailable] -> Mitigation: fail `console` with endpoint-aware guidance and instance name context.
- [Startup reconciliation overhead] -> Mitigation: only perform O(number of known instances) lightweight checks.
- [Flaky tests due to real process execution] -> Mitigation: use injected command runner in unit tests; reserve any integration tests for optional/manual workflows.

## Migration Plan

1. Add new modules for target resolution and VM launch configuration.
2. Refactor `up` to call resolver + launcher and gate persistence on success.
3. Update `up` output text to indicate provisioning success (instance + target + launched VM).
4. Add/adjust tests for success and failure cases.
5. Add detached launch and on-demand serial console attach flow.
6. Add startup runtime reconciliation for PID/lock metadata.
7. Run strict OpenSpec validation for the change artifacts.

Rollback strategy: revert `up` pipeline changes to prior metadata-only behavior if launch stability issues appear.

## Open Questions

- What exact flake output attribute shape should be treated as the canonical VM launch descriptor for `epi up`?
