## Why

The instance state files (target, runtime, mounts) use hand-rolled plain-text formats that each require custom parsing and serialization code. Consolidating into a single JSON file per instance simplifies the codebase, eliminates format-specific parsing bugs, and makes state files easier to inspect and extend.

## What Changes

- **BREAKING**: Replace the separate `target`, `runtime`, and `mounts` plain-text files with a single `state.json` file per instance
- Remove hand-rolled key=value parsing for runtime and line-based parsing for mounts
- Use Yojson (already a dependency for target descriptor caching) for all state serialization
- Update instance discovery to check for `state.json` instead of `target` file
- Update all save/load functions in `Instance_store` to read/write JSON
- Remove `Util.parse_key_value_output` if no longer used elsewhere

## Capabilities

### New Capabilities

### Modified Capabilities
- `instance-state-storage`: The on-disk format changes from separate plain-text files to a single `state.json` per instance. Discovery checks for `state.json` instead of `target`. The directory layout for non-state files (disk.img, cidata/, sockets, keys) is unchanged.

## Impact

- `lib/instance_store.ml` — rewrite save/load/discovery functions
- `lib/util.ml` — potentially remove `parse_key_value_output`
- `test/unit/test_instance_store.ml` — update tests for new format
- `openspec/specs/instance-state-storage/spec.md` — update format requirements
- Existing state directories from previous versions will not be readable (no migration)
