## Context

epi is a CLI tool for managing ephemeral NixOS VMs. All user-facing output currently uses raw `eprintln!`/`println!` — no color, no spinners, no visual hierarchy. Long-running operations (nix builds, SSH polling) show a single static message, making it hard to tell if the tool is hung or working. The `status` and `list` commands use manual string padding with no state differentiation.

The codebase already uses `crossterm` for raw terminal mode in console attachment, so terminal manipulation is not new. The `anyhow` error type is used throughout, giving us full error chains to display.

## Goals / Non-Goals

**Goals:**
- Per-step progress spinners during launch/start/rebuild so users see what's happening
- Colored state indicators (running/stopped/error) in status and list output
- Styled error output with visual hierarchy
- TTY-aware: plain text when piped, styled when interactive
- Minimal API surface — a small `ui` module, not a framework

**Non-Goals:**
- Progress bars with percentage (we don't know completion % for most operations)
- JSON output mode (`--json` flag) — future work
- Verbosity flags (`-v`, `-q`) — future work
- Changing stdout/stderr semantics or exit codes
- Modifying console.rs output (it operates in raw terminal mode)
- Box-drawing table for status (keep it simple for now; easy to add later)

## Decisions

### 1. Use `indicatif` for spinners, `console` for color/TTY detection

**Rationale:** `indicatif` provides spinner/progress bar primitives that handle terminal rewriting, line clearing, and hidden-when-not-TTY behavior. `console` provides `Style` for colored output and `Term` for TTY detection. They're from the same author and integrate well. Both are widely used and well-maintained.

**Alternative considered:** `owo-colors` is lighter but doesn't provide spinners. Using `crossterm` directly for everything would mean reimplementing spinner logic. `dialoguer` adds prompts but we don't need interactive prompts yet.

### 2. Single `ui` module with free functions and a `Step` wrapper

Rather than a trait or callback-based system, the `ui` module exposes:
- `Step::start(msg) -> Step` — starts a spinner on stderr
- `step.finish(msg)` — replaces spinner with ✓
- `step.fail(msg)` — replaces spinner with ✗
- `info(msg)`, `warn(msg)`, `error(err)` — styled one-line output to stderr
- `print_status(...)`, `print_list(...)` — styled output to stdout

**Rationale:** This is the simplest approach. No generics, no traits, no dependency injection. Each command function calls `ui::` directly. The `Step` type wraps `indicatif::ProgressBar` and is the only stateful piece.

**Alternative considered:** Passing a `&dyn ProgressReporter` into `provision()` to decouple UI from business logic. This would be cleaner but adds complexity we don't need — there's exactly one UI (the terminal) and exactly one call site for each operation. We can refactor later if needed.

### 3. Progress reporting happens in command functions, not in `vm_launch`

The `cmd_launch`/`cmd_start`/`cmd_rebuild` functions in `main.rs` already orchestrate provisioning. Rather than threading callbacks into `provision()`, we break the provisioning into visible steps at the command level. This means `provision()` stays unchanged — the command functions wrap each call in `Step::start`/`step.finish`.

The challenge: `provision()` is a single call that does multiple sub-steps internally. To show per-step progress, we need to either:
- (a) Break `provision()` into individually-callable steps, or
- (b) Accept coarser granularity (one spinner for all of provisioning)

**Decision:** Option (b) for now. Show a spinner for `provision()` as a whole ("Provisioning VM...") and a separate spinner for `wait_for_ssh` ("Waiting for SSH..."). These are the two user-visible long-running operations. The internal sub-steps of provisioning (disk, key, ISO, passt, etc.) are fast enough that per-step spinners would just flash by.

If nix builds become a bottleneck worth exposing, we can break out `target::ensure_paths_exist()` as a separate visible step later.

### 4. Color strategy: semantic, not decorative

| Element | Style |
|---------|-------|
| ✓ completed step | green |
| ⠋ in-progress spinner | yellow/default |
| ✗ failed step | red |
| ● running | green |
| ○ stopped | dim |
| Instance names | bold |
| Elapsed time | dim |
| Warnings | yellow |
| Errors | red + bold prefix |

Colors are applied via `console::Style`. Auto-disabled when `NO_COLOR` env is set or stderr is not a TTY (both handled by `console` crate).

### 5. List output: plain aligned columns with colored state dots

Keep the current column-based format but add state indicator dots:
```
INSTANCE         TARGET                                   STATUS      SSH
default          .#vm                                     ● running   127.0.0.1:10422
test-box         .#minimal                                ○ stopped   —
```

No box-drawing characters. Use `—` for empty values instead of blank space. Use `console::pad_str` or manual formatting for column alignment.

### 6. Status output: keep labeled fields, add color

Current format is clean and works well. Just add color to the status value:
```
instance:  default
target:    .#vm
status:    ● running    (green)
ssh port:  10422
serial:    .epi/state/default/serial.sock
disk:      .epi/state/default/disk.img
unit id:   abc123
```

No box-drawing table — it adds visual weight without adding information for a single instance. Easy to add later if desired.

### 7. Error formatting

Replace `eprintln!("error: {e:#}")` with styled output:
```
✗ error: VM failed to boot
  VM exited immediately after launch (no journal output)
```

The `✗ error:` prefix in red+bold, the detail indented and dim. Use anyhow's chain to show context.

## Risks / Trade-offs

**[Risk] Spinner interferes with console attachment** → The `--console` flag on launch runs SSH wait in a background thread while console is attached in raw mode. Spinners on stderr would corrupt the raw terminal. **Mitigation:** Skip spinners when `--console` is active; use plain `eprintln!` for the background SSH wait thread (which already uses it).

**[Risk] Integration tests match on stderr text** → Tests that assert stderr content will break when output changes format. **Mitigation:** Update test assertions. The new format is more structured so assertions can be more targeted (e.g., check for "is ready" rather than the exact line format).

**[Risk] Two new dependencies** → `indicatif` and `console` add compile time and dependency surface. **Mitigation:** Both are well-established crates (indicatif: 4k+ GitHub stars, console: 1k+). They're from the same author (mitsuhiko). The compile-time cost is modest.

**[Trade-off] Coarse provisioning granularity** → Users see one spinner for all of provisioning rather than per-step. This is simpler to implement but provides less visibility into what's happening. Acceptable because most sub-steps are fast; the main wait is nix build (which we could break out later) and SSH polling (which gets its own spinner).
