## Why

`epi up` runs `nix eval` on every invocation to resolve target artifacts, even when nothing has changed. This is slow (1-5s+) and blocks fast iteration. Artifact paths in `/nix/store` are immutable, so a cache keyed on the target string is safe and correct.

## What Changes

- `vm_launch.ml` is split into three modules: `target.ml` (descriptor type, eval, validation, cache), `vm_launch.ml` (launch, seed ISO, networking), and `console.ml` (serial console attachment)
- `target.ml` gains a descriptor cache: SHA256(target) → key-value file in `~/.local/state/epi/targets/`
- `epi up` skips `nix eval` and `nix build` when a valid cached descriptor exists with all paths present on disk
- `epi up --rebuild` forces re-eval and re-build, replacing the cached descriptor

## Capabilities

### New Capabilities

- `target-descriptor-cache`: Cache resolved target descriptors (kernel, disk, initrd, cmdline, cpus, memory_mib) keyed by SHA256 of the target string; validate by checking all artifact paths exist on disk; bust with `--rebuild`

### Modified Capabilities

- `vm-provision-from-target`: `up` now accepts `--rebuild` flag; skips eval+build when cached descriptor is valid

## Impact

- `lib/vm_launch.ml`: split into `target.ml`, `vm_launch.ml`, `console.ml`
- `lib/target.ml`: expanded from thin string wrapper to own descriptor type, resolution, validation, and cache
- `lib/console.ml`: new module for serial console attachment
- `bin/`: CLI wiring for `--rebuild` flag on `up` subcommand
- `lib/dune`: new library entries
- No external dependencies added (uses `Digest` from OCaml stdlib for SHA256)
