## Why

The console's stdin handling uses crossterm's event reader, which parses raw terminal bytes into structured `KeyEvent`s. This destroys the original bytes, requiring us to reconstruct escape sequences for every key type (arrow keys, Home, End, etc.). Arrow keys and other special keys are currently silently dropped because `key_to_bytes` doesn't handle them. This violates the existing spec requirement that "all other input is forwarded to the serial socket verbatim."

## What Changes

- Replace crossterm `event::read()` with raw byte reads from stdin
- Detect the Ctrl-T (`0x14`) + `q`/`Q` detach sequence at the byte level
- Forward all other bytes directly to the serial socket without interpretation
- Keep crossterm only for enabling/disabling raw terminal mode

## Capabilities

### New Capabilities

_None — this is a bug fix against the existing spec._

### Modified Capabilities

_None — the `serial-console-attachment` spec already requires verbatim forwarding. The implementation just doesn't match._

## Impact

- `src/console.rs`: `attach()` stdin reading loop and `key_to_bytes()` function replaced with raw byte forwarding
- `crossterm` dependency: event reading features no longer used (only terminal raw mode)
