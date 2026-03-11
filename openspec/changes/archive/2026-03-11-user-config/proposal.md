## Why

Currently epi only reads project-level config from `.epi/config.toml`. Users have no way to set personal defaults (e.g., preferred target, default mounts) that apply across all projects without committing them to each project's config.

## What Changes

- Add user-level configuration file support, read from `EPI_CONFIG_FILE` env var, or `XDG_CONFIG_HOME/epi/config.toml`, or `~/.config/epi/config.toml`
- Establish a three-tier merge priority: CLI args > project config > user config

## Capabilities

### New Capabilities
- `user-config`: User-level configuration file discovery and loading, with three-tier merge precedence (CLI > project > user)

### Modified Capabilities

## Impact

- `lib/config.ml`: Add user config loading and extend merge to handle three tiers
- `test/unit/test_config.ml`: New tests for user config resolution and merge precedence
