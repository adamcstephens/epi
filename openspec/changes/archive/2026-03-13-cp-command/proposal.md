## Why

There is no way to copy files to or from a running VM without pre-configuring a virtiofs mount. Users need ad-hoc file transfer for quick iterations — grabbing a log, pushing a binary, syncing a config — without planning mounts ahead of time.

## What Changes

- New `epi cp` CLI command that copies files/directories to and from a running instance using rsync over the existing SSH transport
- rsync added to the guest NixOS image (`epi.nix`) and the host wrapper (`wrapper.nix`) so it is guaranteed available on both ends
- Bidirectional path syntax: `epi cp <instance>:/remote/path ./local` and `epi cp ./local <instance>:/remote/path`

## Capabilities

### New Capabilities
- `cp-command`: CLI command and rsync invocation for copying files to/from instances

### Modified Capabilities

## Impact

- `src/main.rs` — new `Cp` command variant and handler
- `nix/nixos/epi.nix` — add `rsync` to guest `environment.systemPackages`
- `nix/wrapper.nix` — add `rsync` to host wrapper PATH
