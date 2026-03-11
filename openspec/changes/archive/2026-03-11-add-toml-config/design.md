## Context

Users currently pass `--target`, `--mount`, and `--disk-size` on every `epi launch` invocation. For projects where these are stable, this is repetitive. The project already uses JSON extensively for internal state, but TOML is a better fit for human-edited configuration files.

The `.epi/` directory already exists for instance state storage. A config file fits naturally alongside it.

## Goals / Non-Goals

**Goals:**
- Let users declare default launch options in a TOML file so they can run `epi launch` without flags
- CLI arguments always override config file values
- Keep the config module simple — read, parse, return typed values

**Non-Goals:**
- Per-instance configuration (future iteration)
- Config file generation/scaffolding (`epi init` deferred to future work)
- Watching config file for changes
- Nested/complex config structures beyond flat keys and arrays

## Decisions

### Use `otoml` for TOML parsing
**Choice:** `otoml` over `toml` (To.ml) or hand-rolled parsing.

**Rationale:** Zero transitive dependencies (only OCaml stdlib), fully TOML 1.0.0 compliant, typed accessor API (`get_string`, `get_array`). The `toml` library requires Menhir + ISO8601 and is only partially spec-compliant.

**Alternatives considered:**
- `toml` (To.ml): More widely used but heavier deps and incomplete spec support
- JSON: Already used internally but no comments, poor UX for hand-edited config
- S-expressions: Native to OCaml but unfamiliar to users

### Config file location: `.epi/config.toml`
**Choice:** `.epi/config.toml` — inside the existing `.epi/` directory alongside `state/`.

**Rationale:** Consistent with existing `.epi/` convention. Not at project root to avoid clutter. Discoverable alongside state directory.

**Alternatives considered:**
- `epi.toml` at project root: More visible but adds top-level clutter
- `~/.config/epi/config.toml`: Global config, wrong scope for project defaults

### Config resolution order: CLI > config file > built-in defaults
**Choice:** Simple two-layer precedence — CLI args win over config file, config file wins over built-in defaults.

**Rationale:** Standard convention. No need for environment variable layer (env vars already control tool paths and behavior, not launch options).

### New module: `lib/config.ml`
**Choice:** Standalone module that reads `.epi/config.toml` and returns an OCaml record.

**Rationale:** Keeps TOML parsing isolated from command logic. The launch command calls `Config.load ()` and merges results with CLI args before passing to `Vm_launch.provision`.

### Config schema (first pass)
```toml
target = ".#dev"
mounts = [".", "~/.config"]
disk_size = "40G"
```

All keys are optional. Missing keys mean "no default, CLI must provide or use built-in default."

### Mount path resolution differs by source
**Choice:** Config mount paths resolve relative to the project root (parent of `.epi/`). CLI `--mount` paths resolve relative to the current working directory.

**Rationale:** Config files are anchored to the project — `mounts = ["src"]` should always mean `<project>/src` regardless of where the user runs `epi` from. CLI args are ephemeral and should respect the user's current location, matching standard CLI conventions. Both sources expand `~` to `$HOME` and pass through absolute paths unchanged.

## Risks / Trade-offs

- **[New dependency]** → `otoml` has zero transitive deps and is a single opam package. Minimal supply chain risk.
- **[Config file not found is silent]** → Absence of `.epi/config.toml` is not an error — the system behaves as today. Malformed TOML is an error with a clear message.
- **[Target becomes optional on CLI]** → If neither CLI nor config provides a target, the launch command must still fail with a clear message explaining both ways to provide it.
