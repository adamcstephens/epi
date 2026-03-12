## Why

Every external command (`nix`, `ssh`, `passt`, `qemu-img`, etc.) is called through `Process.run` which returns a raw `{ status; stdout; stderr }` record. Every call site repeats the same boilerplate: check status, branch on stderr content, construct domain errors. This makes the orchestration logic hard to test without real binaries or fragile fake scripts, and hides failure modes from the type system.

## What Changes

- Introduce module-level interfaces (module types) for `Target`, `Vm_launch`, and other modules that shell out, so that higher-level code (CLI commands, provisioning flows) can depend on a signature rather than a concrete implementation.
- The real implementations keep their `Process.run` orchestration unchanged.
- Tests swap in mock implementations that return typed `result` values directly — no process spawning, no fake binaries.
- Remove the fake binary mocking approach where it exists; e2e tests against real VMs continue to cover real command orchestration.
- **BREAKING**: Test infrastructure changes — existing CLI integration tests that mock binaries will be replaced with in-process unit tests against module interfaces.

## Capabilities

### New Capabilities
- `module-test-boundaries`: Defines the module signatures (module types) that allow swapping real implementations for test doubles. Covers which modules get interfaces, what the signatures look like, and how the dependency injection works.

### Modified Capabilities
- `in-process-test-infrastructure`: Test infrastructure changes to use module-boundary mocking instead of fake binary mocking.

## Impact

- `lib/process.ml` and `lib/process.mli`: Low-level `run` function stays as-is; higher-level wrappers may get result-typed variants.
- `lib/vm_launch.ml`, `lib/target.ml`, `lib/hooks.ml`: Gain module type signatures; implementations unchanged.
- `test/`: CLI integration tests that depend on mock binaries get rewritten as in-process unit tests.
- No runtime behavior changes — this is a testability refactor.
