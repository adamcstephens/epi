## 1. Expose library functions for testing

- [x] 1.1 Expose `generate_epi_json`, `read_ssh_public_keys`, `alloc_free_port`, `ensure_writable_disk`, `generate_ssh_key` in `lib/vm_launch.ml` (add to `.mli` or create one if missing)
- [x] 1.2 Expose `resolve_descriptor_cached`, `descriptor_paths_exist`, `cache_dir` in `lib/target.ml` interface
- [x] 1.3 Verify `dune build` succeeds and existing tests still pass after interface changes

## 2. Add unit tests for epi.json generation

- [x] 2.1 Create `test/unit/test_epi_json.ml` with tests for `generate_epi_json`: new user gets uid, configured user omits uid, no keys omits ssh_authorized_keys, mounts included when present, mounts omitted when empty
- [x] 2.2 Add tests for `read_ssh_public_keys`: reads .pub files from temp dir, handles empty dir
- [x] 2.3 Wire `test_epi_json.ml` into `test/unit/dune` and `test_unit.ml`

## 3. Add unit tests for cache

- [x] 3.1 Create `test/unit/test_cache.ml` with tests for `resolve_descriptor_cached`: cache write after resolve, cache hit skips resolver, cache miss on missing paths triggers re-resolve, --rebuild busts cache
- [x] 3.2 Wire `test_cache.ml` into `test/unit/dune` and `test_unit.ml`

## 4. Add unit tests for provision helpers

- [x] 4.1 Create `test/unit/test_provision.ml` with tests for `alloc_free_port` (returns valid port), `ensure_writable_disk` (copies nix-store disk to overlay path)
- [x] 4.2 Wire `test_provision.ml` into `test/unit/dune` and `test_unit.ml`

## 5. Add in-process integration tests

- [x] 5.1 Create `test/unit/test_provision_integration.ml` that calls `Vm_launch.provision` directly with mock binary env vars (reuse mock_runtime scripts), testing: successful provision writes state, failed provision does not persist, cached descriptor reuse, --rebuild forces re-eval
- [x] 5.2 Wire into `test/unit/dune` and `test_unit.ml`

## 6. Split e2e tests into dedicated binary

- [x] 6.1 Create `test/e2e/` directory with `dune` and `test_e2e.ml` entry point
- [x] 6.2 Move `test_e2e_setup.ml`, `test_lifecycle_e2e.ml`, `test_mount_e2e.ml` to `test/e2e/`
- [x] 6.3 Move `e2e_helpers.ml` to `test/e2e/` (or keep in helpers if shared)
- [x] 6.4 Update `test/dune` to remove e2e test groups and e2e module references
- [x] 6.5 Verify e2e binary runs independently: `dune exec test/e2e/test_e2e.exe -- _build/default/bin/epi.exe -e`

## 7. Reduce CLI integration tests

- [x] 7.1 Remove integration tests from `test/test_*.ml` files that are now covered by unit tests (seed, cache, mount setup, passt setup, port allocation, error formatting, descriptor validation)
- [x] 7.2 Keep CLI smoke tests: help output, missing args, basic launch success/failure, list output format
- [x] 7.3 Verify remaining CLI tests pass and no test groups are empty

## 8. Verify and clean up

- [x] 8.1 Run full unit test suite (`dune test`) and verify all new tests pass
- [x] 8.2 Run remaining integration tests (`dune exec test/test_epi.exe -- _build/default/bin/epi.exe -e`) and verify they pass
- [x] 8.3 Run e2e tests (`dune exec test/e2e/test_e2e.exe -- _build/default/bin/epi.exe -e`) and verify they pass
- [x] 8.4 Verify dune runs unit and integration binaries concurrently
- [x] 8.5 Remove unused helpers from `test/helpers/test_helpers.ml` and `mock_runtime.ml` if any are now dead code
