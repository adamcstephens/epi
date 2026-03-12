## 1. Define module types

- [x] 1.1 Define `Target_resolver` module type in `lib/target.mli` with `val resolve_descriptor : string -> (descriptor, resolve_error) result`
- [x] 1.2 Define `Vm_runner` module type in `lib/vm_launch.mli` with `val launch_vm` and `val wait_for_ssh` signatures
- [x] 1.3 Create real implementations as named modules (e.g., `Target.Real_resolver`, `Vm_launch.Real_runner`) wrapping existing logic

## 2. Wire up dependency injection

- [x] 2.1 Add optional `?resolver:(module Target_resolver)` parameter to `Vm_launch.provision`
- [x] 2.2 Add optional `?runner:(module Vm_runner)` parameter to `Vm_launch.provision`
- [x] 2.3 Default both parameters to the real implementations so existing callers are unchanged
- [x] 2.4 Update `Vm_launch.provision` internals to call through the module parameters instead of directly

## 3. Create test mock modules

- [x] 3.1 Create `test/helpers/mock_modules.ml` with a configurable `Mock_resolver` that returns canned descriptors or errors based on target string
- [x] 3.2 Add a `Mock_runner` that returns canned `runtime` or `provision_error` values, with a call counter
- [x] 3.3 Add helpers for constructing test descriptors and runtimes with sensible defaults

## 4. Convert provision integration tests

- [x] 4.1 Rewrite "successful provision writes state" test to use mock modules instead of shell scripts
- [x] 4.2 Rewrite "failed provision does not persist" test to use mock modules
- [x] 4.3 Rewrite "cached descriptor reuse" test to use mock resolver with call counting
- [x] 4.4 Rewrite "--rebuild forces re-eval" test to use mock resolver with call counting
- [x] 4.5 Verify all converted tests pass with `dune exec test/unit/test_unit.exe`

## 5. Clean up shell mock infrastructure

- [x] 5.1 Remove shell-script mock code from `test_provision_integration.ml` (`with_mock_env` and helpers)
- [x] 5.2 Evaluate whether `mock_runtime.ml` is still needed by CLI integration tests; remove if not
- [x] 5.3 Run full test suite (`dune test`) to verify nothing is broken
- [ ] 5.4 Run e2e tests to verify real binary orchestration is unaffected (requires real VM)
