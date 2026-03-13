## 1. Remove env forwarding

- [x] 1.1 Remove the `std::env::vars()` / `--setenv` block from `run_helper` in `src/process.rs`
- [x] 1.2 Remove the `std::env::vars()` / `--setenv` block from `run_service` in `src/process.rs`

## 2. E2E regression test

- [x] 2.1 Add `e2e_no_env_leak` test: set a sentinel env var (e.g. `EPI_TEST_SENTINEL`), launch a VM, then use `systemctl --user show --property=Environment` to assert the sentinel is absent from both the VM unit (run_service) and the passt unit (run_helper)

## 3. Verify

- [x] 3.1 Run unit tests (`just test`)
- [x] 3.2 Run e2e tests (`just test-e2e`) to confirm all tests pass including the new one
