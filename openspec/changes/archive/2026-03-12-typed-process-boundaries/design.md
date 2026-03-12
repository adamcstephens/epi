## Context

Currently, `Process.run` returns `{ status: int; stdout: string; stderr: string }` and every caller manually checks `status <> 0`, extracts stderr, and constructs domain errors. Tests mock at the binary level: `mock_runtime.ml` writes ~200 lines of shell scripts (resolver, cloud-hypervisor, xorriso, passt, systemd-run, systemctl, virtiofsd) to temp dirs and sets env vars to point at them. This is duplicated across `mock_runtime.ml` and `test_provision_integration.ml`.

The shell mocks are fragile (they encode assumptions about tool behavior in bash), slow (each test spawns real processes), and hard to extend (adding a new test scenario means editing embedded shell strings).

## Goals / Non-Goals

**Goals:**
- Make `Target.resolve_descriptor`, `Vm_launch.provision`, and similar orchestration functions testable without spawning processes
- Replace shell-script mock infrastructure with OCaml module-level test doubles
- Keep the same test coverage: successful provision, failed provision, cached descriptor reuse, rebuild forcing re-eval
- Preserve e2e tests unchanged — they continue testing real binary orchestration

**Non-Goals:**
- Changing runtime behavior — this is purely a testability refactor
- Adding result types to `Process.run` itself — callers that need raw output keep using it
- Mocking `Instance_store` or filesystem operations — those are already testable with temp dirs
- Refactoring the CLI layer or command dispatch

## Decisions

### 1. Use first-class modules for dependency injection, not functors

**Decision**: Pass dependencies as first-class module values to functions that need them, rather than parameterizing entire modules with functors.

**Rationale**: Functors would require restructuring every module into `Make(Deps : S)` which is heavy and changes the public API. First-class modules let us add an optional `?deps` parameter to key functions — the real implementation is the default, tests pass a mock.

**Alternative considered**: OCaml 5 effects for implicit dependency injection. Too experimental, adds conceptual overhead, and the project targets OCaml 5.x but doesn't need effect handlers for this.

**Alternative considered**: Env-var-based binary swapping (current approach). This is what we're replacing — it works but requires real process spawning and shell scripts.

### 2. Define module types for the two key boundaries: target resolution and VM orchestration

**Decision**: Two module types:

```ocaml
module type Target_resolver = sig
  val resolve_descriptor : string -> (Target.descriptor, Target.resolve_error) result
end

module type Vm_runner = sig
  val launch_vm : ... -> (Instance_store.runtime, Vm_launch.provision_error) result
  val wait_for_ssh : ssh_port:int -> ssh_key_path:string -> timeout_seconds:int -> (unit, Vm_launch.provision_error) result
end
```

**Rationale**: These are the two boundaries where process spawning dominates. `Target_resolver` wraps the nix eval / resolver-cmd calls. `Vm_runner` wraps the systemd-run / cloud-hypervisor / passt / virtiofsd orchestration. Everything above these boundaries (provision flow, CLI commands) can be tested with mock implementations.

**Alternative considered**: A single `Process_runner` module type that mocks `Process.run` itself. This is too low-level — tests would still need to construct fake `output` records and the test code would duplicate the status-checking logic.

### 3. Keep `Process.run` unchanged

**Decision**: `Process.run` stays as-is. The module type boundaries sit above it.

**Rationale**: `Process.run` is a thin wrapper around `Unix.open_process_args_full`. It's not the right abstraction level to mock — the interesting logic is in how callers interpret its output (stderr branching, JSON parsing, retry loops). Mocking at the caller level tests that logic directly.

### 4. Migrate tests incrementally — provision integration tests first

**Decision**: Start by converting `test_provision_integration.ml` to use module-level mocks. Keep CLI integration tests working during the transition. Remove `mock_runtime.ml` shell scripts once all consumers are migrated.

**Rationale**: `test_provision_integration.ml` is the heaviest user of mock binaries and the most valuable to convert. CLI tests (`test_up.ml`, `test_down.ml`, etc.) can be converted later or kept as-is if they're thin enough.

## Risks / Trade-offs

- **[Risk] Mock implementations drift from real behavior** → Mitigated by e2e tests that exercise real binaries. The module mocks only need to return plausible typed values, not simulate tool internals.
- **[Risk] First-class module parameters add API complexity** → Mitigated by using optional parameters with defaults. Callers that don't care about injection see the same API as before.
- **[Trade-off] Less orchestration-level test coverage in unit tests** → Accepted. The stderr-branching and retry logic in `Vm_launch.launch_vm_inner` is best tested against real binaries in e2e, not reimplemented in mocks.
