## 1. Add dependency

- [x] 1.1 Add `fast-strip-ansi = "0.13.1"` to Cargo.toml

## 2. Control character stripping

- [x] 2.1 Test: `strip_control_chars` removes ANSI color codes (e.g. `\x1b[32mOK\x1b[0m` → `OK`)
- [x] 2.2 Test: `strip_control_chars` removes non-printable control chars but preserves newlines and carriage returns
- [x] 2.3 Test: `strip_control_chars` passes through normal text unchanged
- [x] 2.4 Implement `strip_control_chars` in `console.rs` using `fast-strip-ansi` + post-filter for remaining control chars

## 3. Scrollback dump

- [x] 3.1 Test: `read_scrollback` reads last N bytes from a file
- [x] 3.2 Test: `read_scrollback` returns full content when file is smaller than limit
- [x] 3.3 Test: `read_scrollback` returns empty string when file does not exist
- [x] 3.4 Implement `read_scrollback` function in `console.rs`

## 4. Integrate into attach flow

- [x] 4.1 Add scrollback dump to `attach` — read console.log, strip, print with separators before socket connection
- [x] 4.2 Verify `attach` still works when console.log is missing (no error, no scrollback)

## 5. Validation

- [x] 5.1 Run `just test` — all unit tests pass
- [x] 5.2 Run `just test-e2e` — all e2e tests pass
- [x] 5.3 Manual test: launch VM, wait for boot, attach console — verify scrollback shows boot output with clean text
