## Why

The integration test suite (~50s for 52 tests) spawns the `epi` binary as a subprocess for every test, relying on mock shell scripts, filesystem polling, and stdout/stderr parsing. Most tests exercise pure OCaml logic (epi.json generation, cache management, descriptor validation, error formatting) that can be tested faster and more reliably by calling module functions directly. The subprocess approach adds fragility (binary path dependency, environment plumbing, shell script mocks) without proportional value for testing internal logic.

Additionally, all non-unit tests live in a single binary, so CLI smoke tests and real-VM e2e tests run sequentially — e2e tests block the fast feedback loop even when only internal logic changed.

## What Changes

- Migrate epi.json generation, cache, mount, passt, port allocation, disk overlay, and error formatting tests from CLI integration tests to in-process unit tests calling `Vm_launch`, `Target`, and `Instance_store` directly
- Extract key functions in `Vm_launch` that are currently private (e.g., `generate_epi_json`, `generate_seed_iso`, `read_ssh_public_keys`, `alloc_free_port`, `ensure_writable_disk`) so they can be called from tests
- Add a thin integration test layer that calls `Vm_launch.provision` in-process with mock binaries (no CLI subprocess) for end-to-end provisioning flow verification
- Reduce CLI-level tests to a minimal set of smoke tests (argument parsing, help output, basic command routing)
- Split e2e tests (e2e-lifecycle, e2e-mount, e2e-setup) into a dedicated `test/e2e/test_e2e.exe` binary so they run independently from fast tests

## Capabilities

### New Capabilities

- `in-process-test-infrastructure`: Test helpers for calling epi library modules directly with isolated state dirs and mock binary paths, replacing the current `run_cli` subprocess pattern

### Modified Capabilities

- `vm-provision-from-target`: Expose internal provisioning functions for direct testing (currently private to `Vm_launch`)
- `target-descriptor-cache`: Expose cache read/write for direct testing
- `vm-user-provisioning`: Expose `generate_epi_json` for direct testing

## Impact

- **lib/vm_launch.ml**: Functions currently used only internally need to be exposed in the module interface (or tested via a test-only entry point)
- **lib/target.ml**: Cache functions may need exposure
- **test/unit/**: Significant expansion — most test logic moves here
- **test/**: Integration test files shrink substantially; only CLI smoke tests and mock-based integration tests remain
- **test/e2e/**: New directory for real-VM e2e tests (moved from test/)
- **test/helpers/mock_runtime.ml**: Simplified — mock shell scripts replaced by mock binary paths for in-process tests; retained for remaining CLI smoke tests
