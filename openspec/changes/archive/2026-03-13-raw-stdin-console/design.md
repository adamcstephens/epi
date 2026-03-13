## Context

`console.rs` currently uses crossterm's `event::read()` to parse stdin into structured `KeyEvent`s, then `key_to_bytes()` reconstructs byte sequences to forward to the serial socket. This approach silently drops any key not explicitly handled (arrow keys, Home, End, Delete, etc.) because the raw bytes are consumed by crossterm's parser.

The existing `serial-console-attachment` spec requires: "All other input is forwarded to the serial socket verbatim."

## Goals / Non-Goals

**Goals:**
- Forward all stdin bytes to the serial socket without interpretation
- Detect Ctrl-T + q/Q detach sequence at the byte level
- Remove the `key_to_bytes` function entirely

**Non-Goals:**
- Changing the detach sequence
- Changing socket connection logic, capture, or timeout behavior
- Removing the crossterm dependency (still needed for raw mode)

## Decisions

### Read raw bytes from stdin instead of crossterm events

Replace `event::poll()` + `event::read()` with non-blocking reads from `std::io::stdin()`. In the attach loop, read available bytes into a buffer from stdin directly.

**Rationale**: Raw byte reads preserve escape sequences exactly as the terminal emits them. No reconstruction needed, no keys silently dropped.

**Alternative considered**: Extend `key_to_bytes` to handle all missing key types. Rejected because it's an ever-growing allowlist that fights against how terminals work — the raw bytes are already correct.

### Byte-level Ctrl-T detection

Scan the stdin buffer for `0x14` (Ctrl-T). When found:
- If `q` or `Q` follows in the same buffer: detach, forwarding any bytes before the `0x14`.
- If `0x14` is the last byte in the buffer: set a `ctrl_t_pending` flag, forward bytes before it, and wait for the next read.
- If the next byte is not `q`/`Q`: forward the buffered `0x14` and continue processing normally.

This matches the existing spec's split-read requirement.

### Non-blocking stdin via raw file descriptor

Use `libc::fcntl` with `O_NONBLOCK` on stdin's fd to enable non-blocking reads, matching how the socket is already handled. This avoids needing a separate thread for stdin.

## Risks / Trade-offs

- **[Risk] Platform portability**: Raw fd manipulation is Unix-only → crossterm raw mode is already Unix-only in this codebase, so no change in portability.
- **[Trade-off] Losing crossterm event abstraction**: We lose structured key events, but we don't need them — the only "event" we care about is a two-byte detach sequence.
