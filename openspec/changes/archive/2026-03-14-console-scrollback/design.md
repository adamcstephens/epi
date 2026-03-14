## Context

`epi console` attaches to a VM's serial socket for interactive use. Since the virtio-console change, all systemd/kernel output is captured to `console.log` by cloud-hypervisor. But when a user attaches, they only see output from that moment forward — they miss boot progress, errors, and any activity before attachment.

The `console.log` file contains raw terminal output including ANSI escape sequences (colors, cursor movement), VT100 control codes, and systemd status protocol sequences. Dumping this raw content would corrupt the user's terminal.

## Goals / Non-Goals

**Goals:**
- Show recent console output as scrollback when `epi console` attaches
- Limit scrollback size to avoid terminal flooding
- Strip control characters so scrollback is clean text

**Non-Goals:**
- Making scrollback configurable via CLI flags (environment variable is sufficient)
- Real-time tailing of console.log during the session (live output comes from the serial socket)
- Filtering or reformatting the scrollback content beyond control character stripping

## Decisions

### Read tail of console.log before socket connection

In the `attach` function, before connecting to the serial socket, read the last N bytes of `console.log` (default 8KB). Strip control characters, print to stdout with a header/footer separator, then proceed with normal socket attachment.

8KB captures roughly the last ~100-200 lines of systemd output — enough to see recent boot activity without overwhelming the terminal.

**Alternative considered**: Read last N lines instead of bytes. Requires scanning the whole file to find line boundaries. Byte-based tail is simpler and O(1) seek.

### Strip ANSI escapes and control characters

Use the `fast-strip-ansi` crate (v0.13.1) which implements a true VT-100/ANSI state machine. This handles ANSI color codes, OSC sequences, systemd status protocol markers, and getty VT100 setup sequences. After stripping ANSI sequences, also strip remaining non-printable control characters (0x00-0x1F) except newline (0x0A) and carriage return (0x0D).

**Alternative considered**: Hand-rolled state machine. Risky — easy to miss edge cases in escape sequence parsing. The crate is well-tested and fast.

### Visual separator between scrollback and live output

Print a clear separator line before and after scrollback so the user knows where history ends:
```
--- scrollback (last 8KB of console.log) ---
<content>
--- live ---
```

### Scrollback size controlled by constant, not CLI flag

Use a constant `SCROLLBACK_BYTES: usize = 8192`. This keeps the interface simple. If we need configurability later, an environment variable (`EPI_CONSOLE_SCROLLBACK_BYTES`) can be added.

## Risks / Trade-offs

- **Remaining control characters**: `fast-strip-ansi` handles ANSI/VT100 sequences but non-printable control chars (e.g. BEL, backspace) may remain. → Post-strip filter removes these, preserving only newlines and carriage returns.

- **Scrollback may split a line**: Reading last N bytes may start mid-line. → Accept: the first line may be truncated, which is fine for context display.
