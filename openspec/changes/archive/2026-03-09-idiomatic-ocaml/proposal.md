## Why

The codebase has grown organically and accumulated patterns that diverge from idiomatic OCaml: deeply nested `match` pyramids instead of `Result.bind`, hand-rolled JSON parsing (~90 lines) instead of a proper library, duplicated utility functions across modules, `failwith` for recoverable errors, no `.mli` files, and an opaque type (`Target.t`) that provides no actual safety. Targeting OCaml 5.4+ lets us also leverage modern stdlib functions.

## What Changes

- Add `yojson` dependency; replace all hand-rolled JSON parsing in `target.ml` with `Yojson.Basic.Util`; use JSON for descriptor cache serialization
- **BREAKING**: `EPI_TARGET_RESOLVER_CMD` must now emit JSON (previously accepted key=value)
- Use `let ( let* ) = Result.bind` to flatten nested match pyramids in `Target`, `Vm_launch`, and `Console`
- Extract duplicated provision-and-report logic in `epi.ml` (`launch_command` and `start_command` share ~36 identical lines across two branches each)
- Change `read_file_if_exists` return type from `string` (empty for missing) to `string option`
- Move shared utilities (`read_file`, `parse_key_value_output`, `contains`, `ensure_parent_dir`) out of `Target`/`Console`/`Process`/`Instance_store` into a `Util` module; deduplicate the two copies of `contains` and `ensure_parent_dir`
- Enforce `Target.t` through internal APIs (`resolve_descriptor`, `validate_descriptor`, `cache_path` take `t` not `string`) or drop the opaque type
- Replace `Option.is_some`/`Option.get` patterns with direct pattern matching
- Rename `Process.result` to `Process.output` to avoid shadowing `Stdlib.result`
- Convert `Process.escape_unit_name` and `Vm_launch.generate_ssh_key` from `failwith` to `Result` returns
- Add `.mli` files for `Target`, `Instance_store`, `Process`, `Console`, `Vm_launch`
- Use OCaml 5.4+ stdlib functions where code is touched (`String.starts_with`, `String.ends_with`, `Fun.protect`, `In_channel`/`Out_channel` modules, `Option.bind`)

## Capabilities

### New Capabilities

_None_ — this is a refactor of existing internals with no new user-facing behavior.

### Modified Capabilities

- `target-descriptor-cache`: Cache serialization format changes from key=value to JSON
- `vm-provision-from-target`: `EPI_TARGET_RESOLVER_CMD` contract changes to require JSON output

## Impact

- **lib/*.ml**: Every library module is touched
- **lib/*.mli**: Five new interface files added
- **dune-project / lib/dune**: `yojson` added as dependency
- **test/**: Tests may need updates for changed internal APIs (e.g. `Process.result` → `Process.output`, `Target.read_file_if_exists` → `Util.read_file`)
- **Existing cached descriptors**: Old key=value cache files won't parse; cache auto-refreshes so this is self-healing
- **Custom target resolvers**: Users with `EPI_TARGET_RESOLVER_CMD` scripts must update them to output JSON
