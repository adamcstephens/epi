## 1. Add otoml dependency

- [x] 1.1 Add `otoml` to `dune-project` dependencies
- [x] 1.2 Run `dune pkg lock` to update the lock file
- [x] 1.3 Add `otoml` to `lib/dune` library dependencies
- [x] 1.4 Verify `dune build` succeeds with the new dependency

## 2. Config module

- [x] 2.1 Create `lib/config.ml` with a record type for config values (target, mounts, disk_size — all optional)
- [x] 2.2 Implement `load` function: read `.epi/config.toml`, parse with otoml, extract typed values
- [x] 2.3 Implement mount path resolution function: expand `~` to `$HOME`, resolve relative paths (including `./` and `../` prefixed) against the detected project root (parent of `.epi/`) to absolute paths
- [x] 2.4 Handle missing file (return all-None record) and invalid TOML (exit with path + parse error)
- [x] 2.5 Write unit tests for: valid config, missing file, invalid TOML, partial config, malformed target value, config mount paths resolve against project root, tilde mount paths

## 3. Mount path resolution for CLI --mount

- [x] 3.1 Apply mount path resolution to CLI `--mount` args (tilde expansion, relative paths resolve against cwd)
- [x] 3.2 Unit tests for CLI mount path resolution: absolute passthrough, relative resolves against cwd, tilde expansion

## 4. Integrate config into launch command

- [x] 4.1 Call `Config.load` in the launch command path and merge with CLI args (CLI wins)
- [x] 4.2 Make `--target` optional on CLI — fall back to config, then error if neither provides it
- [x] 4.3 Apply config `mounts` and `disk_size` as defaults when CLI args are absent
- [x] 4.4 Update error message for missing target to mention both `--target` and `.epi/config.toml`

## 5. Tests for config integration

- [x] 5.1 Unit test: config values used when CLI args absent
- [x] 5.2 Unit test: CLI args override config values
- [x] 5.3 Unit test: no config file and no CLI target produces clear error mentioning config file
- [x] 5.4 CLI integration test: launch with config file providing target (no --target flag)
- [x] 5.5 CLI integration test: launch with --target overriding config target
