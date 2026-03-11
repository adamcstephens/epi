## Context

epi currently loads a single project-level config from `.epi/config.toml` via `Config.load`, then merges CLI args on top via `Config.merge`. There is no user-level config.

## Goals / Non-Goals

**Goals:**
- Support a user-level config file with the same schema as project config
- Three-tier precedence: CLI args > project config > user config
- Standard config file discovery: `EPI_CONFIG_FILE` > `XDG_CONFIG_HOME/epi/config.toml` > `~/.config/epi/config.toml`

**Non-Goals:**
- Config file creation commands or interactive setup
- Different schema for user vs project config
- Nested or profile-based user configs

## Decisions

**Single `Config.t` type for both levels.** The user config and project config share the same `Config.t` record type. A new `Config.merge_configs` function combines user and project configs (project wins), producing a single `Config.t` that is then passed to the existing `Config.merge` for CLI arg resolution.

*Alternative: separate user config type.* Rejected — the fields are identical, adding a type just adds boilerplate.

**Config file discovery in `Config` module.** The user config path resolution (`EPI_CONFIG_FILE` > XDG > default) lives in `config.ml` as a `user_config_path` function.

## Risks / Trade-offs

- [User config silently ignored if malformed] → Return an error, same as project config. Users should know if their config is broken.
- [Env var points to nonexistent file] → If `EPI_CONFIG_FILE` is set but the file doesn't exist, return an error. This distinguishes explicit intent from default discovery.
