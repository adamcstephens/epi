## Context

Instance state is currently stored as three separate plain-text files per instance: `target` (single line), `runtime` (key=value pairs), and `mounts` (one path per line). Each has bespoke parsing and serialization code in `Instance_store`. The project already uses Yojson for target descriptor caching in `Target.ml`.

## Goals / Non-Goals

**Goals:**
- Replace separate plain-text state files with a single `state.json` per instance
- Remove hand-rolled parsing code in favor of Yojson
- Maintain all existing state semantics (optional fields, discovery, clear_runtime)

**Non-Goals:**
- Migration from old format to new — this is a dev tool, not production infrastructure
- Changing the non-state files in the instance directory (disk.img, cidata/, sockets, keys)
- Adding new state fields or changing the runtime type

## Decisions

### Single `state.json` vs separate JSON files
**Decision**: Single `state.json` containing target, runtime, and mounts.

**Rationale**: The three pieces of state are always associated with the same instance and are small. A single file is simpler to manage and atomic to reason about. The alternative (three separate `.json` files) would keep the same file count without benefit.

### JSON structure
**Decision**: Flat top-level object with `target` (required string), `mounts` (optional array), and `runtime` (optional object).

```json
{
  "target": ".#manual-test",
  "mounts": ["/home/alice/src"],
  "runtime": {
    "unit_id": "a1f30d5a",
    "serial_socket": "/path/serial.sock",
    "disk": "/path/disk.img",
    "ssh_port": 45579,
    "ssh_key_path": "/path/key"
  }
}
```

**Rationale**: Mirrors the existing data model directly. `runtime` is null/absent when the VM is stopped, matching the current behavior where the runtime file is deleted. `mounts` defaults to empty array when absent.

### clear_runtime implementation
**Decision**: Read `state.json`, remove the `runtime` key, write it back.

**Rationale**: Simpler than the current approach of deleting a separate file, and keeps the single-file model consistent.

### Yojson.Safe vs Yojson.Basic
**Decision**: Use `Yojson.Safe` (already used in `Target.ml`).

**Rationale**: Consistency with existing code. `Safe` distinguishes int/float which matches our `ssh_port` integer field.

## Risks / Trade-offs

- **[Non-atomic writes]** → Writing JSON requires read-modify-write for `clear_runtime` and `save_runtime`. The window is small and acceptable for a local dev tool.
- **[Breaking existing state]** → Old instances won't be discovered. Acceptable since this is a dev tool and instances are ephemeral. Users just re-create VMs.
- **[Larger diffs for small changes]** → Updating just runtime rewrites the whole file. The files are tiny (<1KB) so this is negligible.
