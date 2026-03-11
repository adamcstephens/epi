## Why

Users must pass `--target`, `--mount`, and other flags on every `epi launch` invocation. For projects where the target and mounts are stable, this is repetitive. A project-level configuration file would let users declare defaults once and override them per-invocation via CLI flags.

## What Changes

- Add `otoml` as a dune-pkg dependency for TOML parsing
- Introduce a project-level configuration file (`.epi/config.toml`) that provides default values for launch options: `target`, `mounts`, `disk_size`
- CLI arguments take precedence over config file values
- Mount paths from both config file and CLI `--mount` are resolved: `~` expands to `$HOME`, relative paths resolve against cwd
- New `epi init` command to scaffold a config file interactively

## Capabilities

### New Capabilities
- `project-config`: Loading, parsing, and merging a `.epi/config.toml` file with CLI arguments to produce resolved launch options

### Modified Capabilities
- `dev-instance-cli`: The `launch` command gains config-file fallback behavior — `--target` becomes optional when a config file provides a default target
- `virtiofs-mount`: Mount paths from `--mount` CLI args are resolved (tilde expansion, relative-to-absolute) before use, consistent with config file mount resolution

## Impact

- New dependency: `otoml` (zero transitive deps)
- `lib/epi.ml`: Launch command argument resolution changes (target no longer unconditionally required via CLI)
- `lib/vm_launch.ml`: No changes — receives resolved values as before
- `.epi/` directory: Gains `config.toml` alongside existing `state/`
