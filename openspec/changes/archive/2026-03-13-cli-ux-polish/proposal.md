## Why

All CLI output is raw `eprintln!`/`println!` with no formatting, color, or progress feedback. Long-running operations like VM provisioning and SSH wait show a single static message, leaving users unsure whether the tool is working or hung. Status and list output uses manual string padding with no visual hierarchy. There's no distinction between success, progress, warning, and error states in the output.

## What Changes

- Add `indicatif` and `console` crate dependencies for progress spinners and styled terminal output
- Create a `ui` module that centralizes all user-facing output behind a small API (spinners, step indicators, styled printing)
- Replace bare `eprintln!` progress messages in launch/start/rebuild with per-step spinners showing elapsed time
- Replace the SSH wait loop's static message with an animated spinner
- Restyle `status` command output with colored state indicators and structured layout
- Restyle `list` command output with colored state dots and proper alignment
- Restyle error output with `✗` prefix and indented error chain
- Add TTY detection so spinners and color are disabled when piped or redirected
- Style hook execution output with step indicators

## Capabilities

### New Capabilities
- `cli-output-styling`: Centralized UI module for styled terminal output — spinners, step indicators, colored status, TTY-aware formatting

### Modified Capabilities
- `dev-instance-cli`: CLI commands gain styled output (progress spinners on launch/start/rebuild/stop/rm, styled status/list display, styled error formatting)
- `host-lifecycle-hooks`: Hook execution messages change from plain `eprintln!` to step-style indicators with success/failure markers

## Impact

- **Dependencies**: Adds `indicatif` and `console` crates
- **Code**: New `src/ui.rs` module; changes to `src/main.rs` (all `cmd_*` functions), `src/hooks.rs` (execute output), `src/vm_launch.rs` (provision steps need to report progress)
- **API boundary change**: `provision()` and related functions may need to accept a progress callback or return step-level status, so the UI layer can update spinners as each step completes
- **Behavior**: Output appearance changes for all commands; semantics (stdout vs stderr, exit codes) unchanged
- **Testing**: Integration tests that match on stderr text will need updating for new formatting
