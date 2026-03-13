## Why

VM resource allocation (CPU, memory) is currently only configurable via the nix target descriptor, requiring a nix rebuild to change. Users also can't customize the default instance name, which is hardcoded to `"default"`. Surfacing these as CLI/config options enables quick iteration without touching nix and lets teams establish project-specific defaults.

## What Changes

- Add `--cpus` CLI option to `launch` command, overriding the target descriptor's `cpus` value
- Add `--memory` CLI option to `launch` command, overriding the target descriptor's `memory_mib` value
- Add `cpus` and `memory` keys to the config file (both project and user), following the existing three-tier precedence (CLI > project > user > descriptor default)
- Add `default_name` key to the config file (both project and user), replacing the hardcoded `"default"` instance name fallback

## Capabilities

### New Capabilities

- `vm-resource-overrides`: CLI and config options for overriding CPU count and memory size, with precedence over target descriptor defaults
- `default-instance-name`: Config option to customize the default instance name used when no name is provided to commands

### Modified Capabilities

- `project-config`: Adding `cpus`, `memory`, and `default_name` keys
- `user-config`: Same new keys apply to user config via existing merge logic
- `dev-instance-cli`: Launch command gains `--cpus` and `--memory` flags; all commands that default to `"default"` instance name now read from config instead

## Impact

- `src/config.rs`: Add new fields to `Config`, `Resolved`; update `merge_configs` and `resolve`
- `src/main.rs`: Add `--cpus` and `--memory` clap args to launch; thread through to VM launch; replace hardcoded `"default"` with config lookup
- `src/vm_launch.rs`: Accept and apply CPU/memory overrides before passing to cloud-hypervisor
- `src/cloud_hypervisor.rs`: Already parameterized on `cpus`/`memory_mib` from descriptor — no changes needed
- `.epi/config.toml`: May optionally be updated with new keys
