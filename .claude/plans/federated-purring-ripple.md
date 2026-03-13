# Fix: unwrap/sentinel/unit-return issues

## Context
Code review identified violations of three rules now in CLAUDE.md:
1. No `unwrap()` outside tests
2. Keep `Option`/`Result` — don't collapse to sentinels
3. Functions that can fail should return `Result`

## Changes

### 1. `console.rs` — unreachable panic + unwrap in map

**`connect_socket` (line 12-27):** Remove `unreachable!()`. Restructure so the error return is the natural fallthrough — e.g. loop returns `Result`, or bail before the loop if `retries == 0`.

**`attach` (line 48-52):** Replace `Option::map` + `unwrap()` with `.map(...).transpose()?` so file creation errors propagate.

### 2. `vm_launch.rs` — unwraps + grow_partition returns unit

**`generate_seed_iso` (line 369):** `iso_path.parent().unwrap()` → `.ok_or_else(|| anyhow!(...))? `

**`generate_seed_iso` (line 406):** `hook.file_name().unwrap()` → `.ok_or_else(|| anyhow!(...))? `

**`grow_partition` (line 309):** Change return type from `()` to `Result<()>`. Propagate the error. Caller at line 304 adds `?`.

### 3. `main.rs` — ssh_port sentinel values

In `cmd_launch`, `cmd_start`, `cmd_rebuild`: replace `runtime.ssh_port.unwrap_or(0)` + `if ssh_port > 0` with `if let Some(ssh_port) = runtime.ssh_port`. Three call sites:
- `cmd_launch` (line 255, checked at 270 and 294)
- `cmd_start` (line 352, checked at 358)
- `cmd_rebuild` (line 575, checked at 581)

### 4. `process.rs` — `stop_unit` returns `Result<bool>` with unchecked bool

Change `stop_unit` to return `Result<()>`, bailing on non-success. The cleanup call in `vm_launch::launch_vm` already uses `let _ =` which handles this. The call in `vm_launch::stop_instance` already uses `?`.

## Files modified
- `src/console.rs`
- `src/vm_launch.rs`
- `src/main.rs`
- `src/process.rs`

## Verification
- `just test` — all unit + CLI tests pass
- `just format` — code formatted
