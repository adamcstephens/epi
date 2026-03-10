## Context

The epi test suite has 52 integration tests that all work by spawning the `epi` binary as a subprocess via `Unix.open_process_args_full`, passing environment variables to configure mock shell scripts, and asserting on exit codes + stdout/stderr text. This takes ~50s and is fragile — tests depend on binary paths, shell script mock behavior, and filesystem polling loops.

The library modules (`Vm_launch`, `Target`, `Instance_store`, `Console`, `Process`) contain the actual logic, but many key functions are not exposed in module interfaces. Existing unit tests only cover `Target` (6 tests), `Instance_store` (8 tests), and `Vm_launch` (in `test/unit/test_vm_launch.ml`).

Additionally, all non-unit tests currently live in a single `test_epi` binary. This means CLI smoke tests, mock-based integration tests, and real-VM e2e tests all share the same binary and run sequentially. E2e tests require a real VM and should not block the fast feedback loop.

## Goals / Non-Goals

**Goals:**
- Expose key `Vm_launch` and `Target` functions so they can be called directly from tests
- Move epi.json generation, cache, mount setup, passt setup, port allocation, error formatting, and descriptor validation tests to unit tests
- Create a thin in-process integration layer that calls `Vm_launch.provision` directly (with mock binary paths via env vars) instead of spawning the CLI
- Reduce CLI-level tests to argument parsing smoke tests
- Split tests into separate binaries (unit, integration/CLI smoke, e2e) so they can run concurrently and e2e tests don't block development
- Cut test suite time significantly

**Non-Goals:**
- Rewriting the production code logic — only exposing existing functions
- Achieving 100% unit test coverage — focus on migrating what's currently integration-tested
- Removing the CLI test infrastructure entirely — keep it for smoke tests

## Decisions

### 1. Expose functions via the existing `epi` library, not a test-only library

**Decision:** Add functions to `vm_launch.mli` / `target.mli` rather than creating a separate `epi_test_internals` library.

**Rationale:** The functions being exposed (`generate_epi_json`, `read_ssh_public_keys`, `alloc_free_port`, `ensure_writable_disk`, cache read/write) are legitimate public API surface. They were only private because the CLI was the sole consumer. Exposing them makes the library more useful and testable without adding build complexity.

**Alternative considered:** A `epi_internals` library that re-exports private functions — rejected as unnecessary indirection.

### 2. Unit tests call OCaml functions with temp dirs, not mock shell scripts

**Decision:** Unit tests for epi.json generation, cache, etc. will call the OCaml functions directly, using `with_temp_dir` for isolation and real file I/O for state. No mock shell scripts needed for most tests.

**Rationale:** The mock shell scripts exist to simulate binary behavior when testing through the CLI. When calling functions directly, we can pass paths to temp files and assert on return values and file contents.

### 3. In-process integration tests replace most CLI subprocess tests

**Decision:** For tests that need to exercise the full provisioning flow (e.g., "launch writes cache after successful provision"), call `Vm_launch.provision` directly with env vars pointing to mock binaries. The mock shell scripts from `mock_runtime.ml` can still be used for the mock binaries themselves, but we skip the CLI parsing layer.

**Rationale:** This tests the same code paths without subprocess overhead. The env var mock approach (`EPI_CLOUD_HYPERVISOR_BIN`, `EPI_TARGET_RESOLVER_CMD`, etc.) works identically whether called from the CLI or from test code.

### 4. Keep a minimal CLI smoke test suite

**Decision:** Retain ~5-10 CLI tests that verify argument parsing, help output, and basic command routing. These use the existing `run_cli` infrastructure.

**Rationale:** The CLI layer (cmdlang argument parsing, command dispatch) is real code that should be tested, but it doesn't need 52 tests. A handful of smoke tests suffices.

### 5. Expand test/unit/ rather than creating a new test directory

**Decision:** Add new unit test modules to `test/unit/` alongside the existing `test_target.ml`, `test_instance_store.ml`, and `test_vm_launch.ml`.

**Rationale:** The directory and dune config already exist. New modules (e.g., `test_epi_json.ml`, `test_cache.ml`, `test_provision.ml`) follow the same pattern.

### 6. Split tests into three separate binaries

**Decision:** Split the current single `test_epi` binary into three:
- **`test/unit/test_unit.exe`** — unit tests calling library functions directly (fast, no subprocesses)
- **`test/test_epi.exe`** — CLI smoke tests and mock-based integration tests (medium speed, spawn epi binary with mocks)
- **`test/e2e/test_e2e.exe`** — real-VM e2e tests (slow, require provisioned VM)

**Rationale:** Currently all tests are in one or two binaries, so running `dune test` executes everything sequentially. Splitting into separate binaries lets dune run them concurrently. More importantly, e2e tests that require a real VM have fundamentally different setup requirements and failure modes — they should be a separate binary that can be run independently (e.g., `dune exec test/e2e/test_e2e.exe -- _build/default/bin/epi.exe -e`). This keeps the fast test loop (unit + integration) under a few seconds while e2e tests run separately when needed.

**Structure:**
```
test/
  dune              → test_epi (CLI smoke + mock integration)
  test_epi.ml       → registers only smoke/mock test groups
  unit/
    dune            → test_unit (unit tests)
    test_unit.ml    → registers unit test groups
  e2e/
    dune            → test_e2e (real-VM tests)
    test_e2e.ml     → registers e2e-lifecycle, e2e-mount, e2e-setup
```

## Risks / Trade-offs

- **[Risk] Exposing functions changes the public API surface** → These are stable internal functions unlikely to churn. The library is only consumed by the epi binary and tests.
- **[Risk] Some integration tests catch CLI-layer bugs that unit tests miss** → Mitigated by keeping a small CLI smoke test suite that exercises the full binary path for major commands.
- **[Risk] Mock binaries still needed for in-process integration tests** → The mock shell scripts are simple and stable. This is an incremental improvement, not a full rewrite.
- **[Trade-off] Three test binaries instead of two** → More binaries means more build targets, but dune handles this well and the concurrency benefit outweighs the complexity. Each binary has a clear responsibility.
