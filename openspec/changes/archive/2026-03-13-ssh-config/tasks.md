## 1. Extract SSH Module

- [x] 1.1 Create `src/ssh.rs` with `ssh_user()` and `ssh_target()` moved from `main.rs`, and register in `lib.rs`
- [x] 1.2 Update `main.rs` to use `epi::ssh::ssh_user` and `epi::ssh::ssh_target`
- [x] 1.3 Run `just test` to verify no regressions

## 2. SSH Config Generation

- [x] 2.1 Write test for `ssh::generate_config` that asserts correct config file contents given instance name, port, user, and key path
- [x] 2.2 Implement `ssh::generate_config` function that writes the SSH config file to `<state_dir>/<instance_name>/ssh_config`
- [x] 2.3 Call `ssh::generate_config` right after provisioning (before `wait_for_ssh`) in `cmd_launch`, `cmd_start`, and `cmd_rebuild`

## 3. Refactor Internal SSH Commands

- [x] 3.1 Add `ssh::config_path(instance)` helper that returns the config file path
- [x] 3.2 Refactor `cmd_ssh` to use `ssh -F <config_path> <instance_name>`
- [x] 3.3 Refactor `cmd_exec` to use `ssh -F <config_path> <instance_name>`
- [x] 3.4 Refactor `cmd_cp` to use `ssh -F <config_path>` in rsync invocation
- [x] 3.5 Move `wait_for_ssh` from `vm_launch.rs` into `ssh.rs`, refactored to use `-F <config_path>`
- [x] 3.6 Run `just test` to verify no regressions

## 4. SSH Config CLI Subcommand

- [x] 4.1 Add `ssh-config` subcommand to CLI parser (clap) and implement `cmd_ssh_config` handler
- [x] 4.2 Skipped CLI integration tests (no CLI test framework; e2e covers it)

## 5. Cleanup

- [x] 5.1 Removed `ssh_target()` and `ssh_user()` from `main.rs`, removed dead `ssh::target()` from `ssh.rs`
- [x] 5.2 Run `just format` and `just lint`
- [x] 5.3 Run `just test` to verify all unit and integration tests pass
- [x] 5.4 Run `just test-e2e` to verify end-to-end tests pass
