## Context

Existing integration tests use `mock_runtime.ml` which replaces cloud-hypervisor, virtiofsd, passt, and the nix resolver with shell scripts that simulate behavior. This gives fast, reliable unit-level coverage but cannot catch issues in real VM interactions: cloud-init metadata handling, systemd mount generation, actual SSH connectivity, or virtiofs file access.

Manual testing is done ad-hoc via `dune exec epi -- launch --target '.#manual-test'`. There is no automated integration test suite that exercises the library against real VMs.

## Goals / Non-Goals

**Goals:**
- Automated integration tests that call OCaml library functions directly against real VMs
- Test mount functionality: provision with mount paths, verify volume accessible in guest
- Test basic VM lifecycle: provision, SSH connectivity, stop, start, remove
- Tests runnable from the dev shell with `dune test` or `dune exec`
- Clean teardown even on test failure

**Non-Goals:**
- CLI argument parsing coverage (existing unit tests handle this)
- CI integration (requires cloud-hypervisor + systemd user session — future work)
- Performance testing or benchmarking
- Testing networking/port-forwarding features

## Decisions

### Call library functions directly, not the CLI

Tests call `Vm_launch.provision`, `Vm_launch.wait_for_ssh`, `Epi.stop_instance`, `Instance_store` operations, etc. No shelling out to the `epi` binary.

**Rationale**: The goal is to test VM provisioning and interaction logic, not CLI parsing. Direct function calls give clearer error reporting (OCaml types vs. parsing stderr), faster execution (no subprocess overhead), and the ability to inspect intermediate state (e.g., the `runtime` record returned by `provision`).

**Alternative**: Shell out to the CLI binary. Rejected because it conflates CLI parsing bugs with VM interaction bugs and makes assertions harder.

### Use SSH via `Process.run` for guest verification

Tests verify guest state by running SSH commands directly using `Process.run` with the SSH key and port from the `runtime` record, rather than going through any higher-level exec abstraction.

**Rationale**: Keeps tests focused on what they're verifying (mounts, connectivity) without depending on the exec command implementation. The SSH connection details are available directly from `Instance_store.runtime`.

### Use alcotest `Slow` speed level in existing test suite

E2e tests will be tagged `` `Slow `` in the existing test suite rather than a separate binary. Alcotest skips `` `Slow `` tests by default — they only run when `--quick-only=false` (or `-e`) is passed.

**Rationale**: Alcotest has built-in support for slow test separation. This avoids a separate build target and test runner while still keeping `dune test` fast by default.

### Use `.#manual-test` target

E2e tests will use the existing `.#manual-test` NixOS configuration. No new NixOS configs needed.

**Rationale**: Reusing the existing config avoids duplication and tests the same thing developers test manually.

### Unique instance names per test

Each test generates a unique instance name (e.g., `e2e-mount-<random>`) to avoid collisions.

**Rationale**: Prevents flaky failures from leftover state.

### Always generate SSH key

All tests pass SSH key generation through the provision flow to avoid depending on the user's SSH key.

### Cleanup via direct library calls

Each test registers cleanup that calls `Epi.stop_instance` and `Instance_store.remove` directly, wrapped in `Fun.protect ~finally`.

**Rationale**: Consistent with the direct-function-call approach. No need to shell out for cleanup.

## Risks / Trade-offs

- **[Slow tests]** → Each test boots a VM (~10-30s). Accept this for e2e; keep the suite small and focused.
- **[System resource requirements]** → Needs cloud-hypervisor, systemd user session, ~1GB memory per VM. Documented as prerequisites.
- **[Flaky cleanup]** → If the test process is killed (SIGKILL), VMs may leak. Mitigated by unique names and manual cleanup instructions.
- **[Nix build time]** → First run needs to build the NixOS config. Subsequent runs use the nix store cache.
- **[Library API coupling]** → Tests are coupled to internal function signatures, not a stable CLI. This is fine — these are internal integration tests, and signature changes should update the tests.
