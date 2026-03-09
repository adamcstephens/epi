## Context

The epi codebase is an OCaml 5.3+ CLI for managing development VM instances via Nix flake targets. It has 6 library modules (`epi.ml`, `instance_store.ml`, `process.ml`, `target.ml`, `vm_launch.ml`, `console.ml`) totaling ~2100 lines. Dependencies are minimal: `cmdlang`, `cmdliner`, `unix`, `alcotest`.

The code works correctly but has accumulated non-idiomatic patterns: hand-rolled JSON parsing, nested match pyramids, duplicated utilities across modules, mixed error strategies (exceptions + Result + string errors), no module interfaces, and an opaque type that doesn't actually constrain anything.

## Goals / Non-Goals

**Goals:**
- Replace hand-rolled JSON with `yojson` to eliminate fragile parsing code
- Flatten nested `match` chains using `Result.bind` / `let*`
- Deduplicate utilities and establish correct module dependency direction
- Make error handling uniform: Result for expected failures, exceptions only for bugs
- Add `.mli` files to enforce module boundaries and document public APIs
- Use OCaml 5.4+ stdlib features where they simplify touched code

**Non-Goals:**
- Changing any user-facing CLI behavior (except the `EPI_TARGET_RESOLVER_CMD` JSON requirement)
- Adding new features or capabilities
- Introducing a monadic framework or PPX dependencies
- Restructuring the module hierarchy beyond what's needed for utility deduplication
- Performance optimization

## Decisions

### 1. Add `yojson` (not `ezjsonm`, not PPX)

**Choice:** `yojson` with `Yojson.Basic.Util` for manual field extraction.

**Alternatives considered:**
- `ezjsonm` — wraps `jsonm`, more ergonomic but less widely used; `yojson` is the de facto standard
- `ppx_yojson_conv` — auto-derives serializers from types, but adds PPX toolchain complexity; the project has only two JSON shapes (descriptor, cache) so manual extraction is fine
- Keep hand-rolled — works today but is fragile (escape handling bugs, can't handle nested structures)

**Rationale:** `yojson` has zero transitive deps beyond what we already have, is the most widely used OCaml JSON library, and `Yojson.Basic.Util` provides exactly the field-extraction combinators we need. No PPX needed for two simple record shapes.

### 2. Create `Util` module for shared functions

**Choice:** New `lib/util.ml` containing: `read_file`, `ensure_parent_dir`, `contains`, `parse_key_value_output`.

**Alternatives considered:**
- Inline everything at call sites — would duplicate `ensure_parent_dir` and `contains`
- Put in `Process` — wrong abstraction level; file reading isn't process execution
- Keep in `Target` — creates backwards dependency (`Instance_store` → `Target` for file I/O)

**Rationale:** A small utility module with 4-5 functions fixes the dependency direction without over-abstracting. Functions are genuinely shared (2+ callers each). The module has no `.mli` — all functions are public, all are simple.

### 3. Module-local `let*` (not a shared `Result_syntax` module)

**Choice:** Define `let ( let* ) = Result.bind` at the top of each module that uses it.

**Alternatives considered:**
- Shared `Result_syntax` module with `let*` and `let+` — adds a module for one line
- Global open of a syntax module — violates "explicit namespace references" preference
- `ppx_let` — PPX dependency for sugar we can do in 1 line

**Rationale:** One line per module, no new dependencies, no opens. Idiomatic for OCaml 5.x. Each module is self-contained.

### 4. Enforce `Target.t` through internal APIs

**Choice:** Make `resolve_descriptor`, `validate_descriptor`, `cache_path`, etc. take `Target.t` instead of `string`. The `.mli` keeps `type t` abstract.

**Alternatives considered:**
- Drop `Target.t` entirely — loses the validated-target concept; `of_string` validation becomes pointless
- Keep current state — `t = string` with functions taking `string` provides zero safety

**Rationale:** The `of_string` validation (must contain `#`, both parts non-empty) is meaningful. Making internal functions take `t` ensures that validated targets flow through the system without re-validation. The `.mli` hides `type t = string` so callers can't bypass `of_string`.

### 5. `Process.output` (not `Process.run_result` or `Process.exec_result`)

**Choice:** Rename `Process.result` → `Process.output`.

**Rationale:** `output` is concise, describes what the type contains (the output of a process), and doesn't shadow `Stdlib.result`. The record fields (`status`, `stdout`, `stderr`) read naturally as `Process.output`.

### 6. Descriptor cache format: JSON

**Choice:** Change cache files from key-value text to JSON using `yojson`.

**Alternatives considered:**
- Keep key-value for cache, use JSON only for nix eval — two serialization formats for the same data
- Use s-expressions — natural for OCaml but unfamiliar for debugging; JSON is human-readable

**Rationale:** Since we're adding `yojson` anyway, unify on one format. The cache is self-healing (miss triggers re-eval), so the format change requires no migration. JSON round-trips through `Yojson.Basic.to_file` / `from_file` with zero custom parsing.

### 7. `.mli` scope: five library modules, not `Util`

**Choice:** Add `.mli` for `Target`, `Instance_store`, `Process`, `Console`, `Vm_launch`. Skip `Util` (all functions public) and `Epi` (entry point, fully public).

**Rationale:** These five modules have internal helpers that shouldn't be part of the public API (e.g., `Target.find_json_string`, `Console.write_all`, `Process.setenv_args`). The `.mli` files hide these while documenting the contract. `Util` has no private functions. `Epi` is the command definition module — hiding commands would be pointless.

### 8. `escape_unit_name` and `generate_ssh_key` return Result

**Choice:** `Process.escape_unit_name : string -> (string, string) result`. `Vm_launch.generate_ssh_key : instance_name:string -> ((string * string), provision_error) result`.

**Alternatives considered:**
- Keep `failwith` — forces callers to mix `try/with` into Result chains
- Return `option` — loses error details

**Rationale:** Both are external command calls that can fail in expected ways (binary not found, key generation error). Returning Result lets callers compose with `let*` instead of wrapping in `try`.

## Risks / Trade-offs

- **[BREAKING: `EPI_TARGET_RESOLVER_CMD` must output JSON]** → Documented in proposal. Any custom resolver scripts must be updated. The key-value format was undocumented anyway; JSON is a cleaner contract.
- **[Cache invalidation on format change]** → Self-healing: cache miss triggers re-eval. First run after upgrade is slightly slower. No migration needed.
- **[`yojson` dependency size]** → `yojson` is a single opam package with zero transitive deps beyond `seq` (in stdlib since 4.07). Minimal footprint.
- **[`.mli` maintenance burden]** → Must update interface when adding public functions. Trade-off is worth it for compile-time encapsulation and documentation.
- **[Util module]** → Risk of becoming a dumping ground. Mitigated by keeping it to genuinely shared functions (2+ callers). Currently 4-5 functions.
