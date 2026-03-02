## Why

Users need a convenient way to attach to VM serial consoles after creating instances. Currently, the `console` command exists but doesn't actually attach to the serial console. Additionally, when running `up --console`, users want immediate console attachment as soon as the VM starts.

## What Changes

- Implement `epi console [INSTANCE]` to attach to running VM serial sockets directly in OCaml
- Add `--console` flag to `epi up` command that immediately attaches to serial console after VM creation
- Both commands use the same native socket relay path for interactive console access
- Console attachment is blocking and streams stdin/stdout through the serial socket

## Capabilities

### New Capabilities
- `serial-console-attachment`: Console commands that relay stdin/stdout to VM serial sockets

### Modified Capabilities
- `vm-detached-serial-console`: Extend to support immediate console attachment during `up --console` workflow

## Impact

- No new external console dependency is required
- `epi console` runs an in-process socket relay in the CLI
- `epi up --console` will block and attach console immediately after VM backgrounding
- VM serial socket paths must be available and accessible
