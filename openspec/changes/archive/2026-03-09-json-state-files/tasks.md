## 1. JSON serialization helpers

- [x] 1.1 Add `runtime_to_json` and `runtime_of_json` functions to `Instance_store`
- [x] 1.2 Add `state_to_json` and `state_of_json` functions that handle the full state.json structure (target, mounts, runtime)

## 2. Rewrite save/load functions

- [x] 2.1 Replace `save_target`, `save_runtime`, `save_mounts` with a single `save_state` that writes `state.json`
- [x] 2.2 Replace `load_target`, `load_runtime`, `load_mounts` with functions that read from `state.json`
- [x] 2.3 Update `clear_runtime` to read `state.json`, remove runtime key, and write back
- [x] 2.4 Update `set`, `set_provisioned`, `find`, `find_runtime` to use the new save/load

## 3. Update instance discovery

- [x] 3.1 Update `list` to check for `state.json` with valid `target` field instead of a `target` file

## 4. Clean up old parsing code

- [x] 4.1 Remove `Util.parse_key_value_output` if no longer used elsewhere

## 5. Update tests

- [x] 5.1 Update `test_instance_store.ml` round-trip tests to work with the new JSON format
- [x] 5.2 Verify all existing test scenarios pass with the new implementation
