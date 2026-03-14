## Why

When `epi console` attaches to a VM, the user sees only live serial output from that point forward. Boot messages, systemd output, and any activity that happened before attachment are invisible. With the recent switch to virtio-console file capture (`console.log`), all this output is already on disk — but the user has no way to see it without manually reading the file.

## What Changes

- When `epi console` attaches, dump the tail of `console.log` as scrollback before connecting to the live serial socket. This gives the user context about what happened before they attached.
- Limit scrollback to a configurable maximum (e.g. last 8KB) to avoid flooding the terminal after long-running VMs.
- Strip ANSI escape sequences and non-printable control characters from the scrollback dump so the output is clean, readable text — the raw file contains terminal control codes from systemd and getty that would corrupt the user's terminal.
- Print a visual separator between scrollback and live output so the user knows where history ends and live begins.

## Capabilities

### New Capabilities
- `console-scrollback`: On attach, `epi console` dumps recent console.log content (stripped of control characters) before connecting to the live serial socket.

### Modified Capabilities
- `serial-console-attachment`: The attach flow gains a scrollback dump step before the live socket relay begins.

## Impact

- `src/console.rs`: Add scrollback logic to `attach` — read tail of console.log, strip control characters, print to stdout before socket connection.
