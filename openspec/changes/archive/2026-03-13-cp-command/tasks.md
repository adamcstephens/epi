## 1. Nix packaging

- [x] 1.1 Add `rsync` to `environment.systemPackages` in `nix/nixos/epi.nix`
- [x] 1.2 Add `rsync` to the wrapper PATH in `nix/wrapper.nix`

## 2. Path parsing

- [x] 2.1 Unit tests for path parsing (local-only, host-to-remote, remote-to-host, default instance)
- [x] 2.2 Implement path parsing: split on first `:` to detect `<instance>:<path>` vs local path

## 3. CLI command

- [x] 3.1 CLI integration test: verify `epi cp` with a missing instance produces the expected error
- [x] 3.2 Add `Cp` variant to the `Command` enum in `src/main.rs` with source/dest positional args
- [x] 3.3 Implement `cmd_cp` — resolve instance runtime, build rsync args with `-e "ssh ..."` and `--progress`, exec into rsync

## 4. E2E

- [x] 4.1 E2E test: copy a file to a running VM and verify it arrives
