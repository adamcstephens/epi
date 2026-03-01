## 1. Target Resolution and Launch Descriptor

- [x] 1.1 Define an internal VM launch descriptor type for `up` (required artifacts, CPU/memory, runtime options).
- [x] 1.2 Implement target evaluation for `--target <flake#config>` that resolves into the descriptor.
- [x] 1.3 Validate descriptor completeness and file/path accessibility before launch.
- [x] 1.4 Return stage-specific errors for target evaluation and descriptor validation failures.

## 2. cloud-hypervisor Provisioning Flow in `up`

- [x] 2.1 Add a dedicated launcher module that invokes cloud-hypervisor from the resolved descriptor.
- [x] 2.2 Refactor `up` command flow to execute: parse target -> resolve descriptor -> launch VM -> persist instance state.
- [x] 2.3 Ensure instance-to-target mapping is written only after successful VM provisioning.
- [x] 2.4 Update `up` success and failure output to include clear provisioning status and actionable error context.

## 3. Tests and Regression Coverage

- [x] 3.1 Add tests for successful named/default instance provisioning paths in `up`.
- [x] 3.2 Add tests that failed provisioning does not persist or mutate instance mapping.
- [x] 3.3 Add tests for stage-specific failure messages (target resolution failure, missing launch inputs, launcher exit failure).
- [x] 3.4 Update existing `up` behavior tests to match new provisioning semantics while preserving target-format validation.

## 4. Validation and Developer Workflow

- [x] 4.1 Run project test suite for CLI behavior changes and fix regressions.
- [x] 4.2 Run `openspec validate up-create-cloud-hypervisor-vm --strict` and resolve any artifact issues.
- [x] 4.3 Confirm `openspec status --change up-create-cloud-hypervisor-vm` reports apply-ready artifacts.

## 5. Detached Runtime and Console Access

- [x] 5.1 Launch cloud-hypervisor in detached mode and persist runtime metadata needed for later attachment.
- [x] 5.2 Add `epi console [instance]` to attach to per-instance serial console endpoint.
- [x] 5.3 Add clear errors for missing/unavailable serial endpoints and non-running instances.

## 6. PID/Lock Startup Reconciliation

- [x] 6.1 Extend runtime state with tracked PID and lock-relevant metadata (for example disk path and serial socket).
- [x] 6.2 Reconcile runtime state at CLI startup with lightweight liveness checks.
- [x] 6.3 Surface actionable lock conflict diagnostics when a running process already holds the disk lock.
- [x] 6.4 Add tests for stale PID cleanup, active PID detection, and lock conflict reporting.
