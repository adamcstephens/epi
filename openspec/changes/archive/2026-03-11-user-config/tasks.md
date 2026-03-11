## 1. User config file discovery

- [x] 1.1 Add `user_config_path` function to `config.ml` that resolves path via `EPI_CONFIG_FILE` > `XDG_CONFIG_HOME/epi/config.toml` > `~/.config/epi/config.toml`
- [x] 1.2 Add `load_user` function that loads user config (error if `EPI_CONFIG_FILE` set but missing, empty config if default path missing)
- [x] 1.3 Write unit tests for `user_config_path` with various env var combinations
- [x] 1.4 Write unit tests for `load_user` (file exists, file missing, env var points to missing file)

## 2. Three-tier merge

- [x] 2.1 Add `merge_configs` function that combines user config and project config (project wins over user)
- [x] 2.2 Update call sites to load user config and merge before calling `Config.merge`
- [x] 2.3 Write unit tests for three-tier precedence (CLI > project > user)

## 3. Integration

- [x] 3.1 Verify `dune test` passes with all new tests
- [x] 3.2 Manual test: set user config file and confirm values are picked up
