## 1. Dependencies and Module Setup

- [x] 1.1 Add `indicatif` and `console` crates to Cargo.toml
- [x] 1.2 Create `src/ui.rs` module with `Step` type wrapping `indicatif::ProgressBar` (start/finish/fail methods) and register in `lib.rs`
- [x] 1.3 Add `info()`, `warn()`, `error()` styled message functions to `ui` module

## 2. Launch/Start/Rebuild Progress

- [x] 2.1 Refactor `cmd_launch` to use `Step` spinner during `provision()` call and `wait_for_ssh()` call, with ✓/✗ completion markers
- [x] 2.2 Refactor `cmd_start` to use `Step` spinners for provisioning and SSH wait
- [x] 2.3 Refactor `cmd_rebuild` to use `Step` spinners for stop, provisioning, and SSH wait
- [x] 2.4 Skip spinners in `cmd_launch` when `--console` is active (use plain `eprintln!` for background SSH wait thread)

## 3. Stop and Remove Output

- [x] 3.1 Refactor `cmd_stop` to use `ui::info()` for status messages
- [x] 3.2 Refactor `cmd_rm` to use `ui::info()` for status messages

## 4. Status and List Display

- [x] 4.1 Refactor `cmd_status` to use colored state dots (green ● running, dim ○ stopped) and bold instance name
- [x] 4.2 Refactor `cmd_list` to use colored state dots and `—` for empty SSH values

## 5. Error and Warning Output

- [x] 5.1 Replace `eprintln!("error: {e:#}")` in `main()` with `ui::error()` showing styled ✗ prefix and indented error chain
- [x] 5.2 Replace warning `eprintln!` calls in `hooks.rs` with `ui::warn()`
- [x] 5.3 Replace `eprintln!("running hook: ...")` in hook execution with `Step` spinner per hook

## 6. Testing

- [x] 6.1 Update integration test stderr assertions for new output format (N/A — no CLI stderr assertions exist)
- [x] 6.2 Run `just test` to verify all unit and integration tests pass
- [x] 6.3 Manual test: `just run launch` and verify spinner output in terminal
- [x] 6.4 Manual test: pipe `epi list` to `cat` and verify no ANSI codes in output
