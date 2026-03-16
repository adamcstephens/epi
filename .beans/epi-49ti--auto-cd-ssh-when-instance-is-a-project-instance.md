---
# epi-49ti
title: auto-cd ssh when instance is a project instance
status: completed
type: task
priority: normal
created_at: 2026-03-16T00:45:42Z
updated_at: 2026-03-16T03:27:51Z
---

## Design

**Goal:** When `epi ssh` connects to a project instance, auto-cd into the project directory (mirrored mount path).

**Approach:**

1. Add a `pkgs.writeShellApplication` script to `environment.systemPackages` in `nix/nixos/epi.nix`
2. Add `RemoteCommand` and `RequestTTY force` to the SSH config when `project_dir` is set

**Guest script (e.g. `epi-ssh-entry`):**
- Takes project path as argument
- If path exists: `cd` into it, `exec $SHELL -l`
- If path doesn't exist: warn, stay in home, `exec $SHELL -l`

**SSH config changes (`src/ssh.rs`):**
- Thread `project_dir: Option<&str>` into `generate_config()`
- When `Some(path)`: add `RemoteCommand epi-ssh-entry <path>` and `RequestTTY force`
- When `None`: no change (current behavior)

**Scope:**
- `epi ssh` only — `epi exec` unchanged
- Non-project instances: no-op (no `RemoteCommand` added)
- No opt-out flag needed

**Assumptions:**
- Guest mount paths mirror host paths
- `project_dir` is already in `InstanceState`

## Tasks

- [x] Add `epi-ssh-entry` script via `writeShellApplication` to `environment.systemPackages` in `nix/nixos/epi.nix`
- [x] Thread `project_dir` into `ssh::generate_config()` in `src/ssh.rs`
- [x] Add `RemoteCommand` and `RequestTTY force` to SSH config when `project_dir` is `Some`
- [x] Update `cmd_ssh` call site to pass `project_dir` through
- [x] Rebuild test image and verify behavior


## Summary of Changes

- Added `epi-ssh-entry` shell script to the NixOS guest image via `writeShellApplication`
- Extended `ssh::generate_config()` and `ssh::trust_host_key()` with `project_dir` parameter
- SSH config now includes `RemoteCommand epi-ssh-entry <path>` and `RequestTTY force` for project instances
- All existing call sites updated to thread `project_dir` through
- Unit tests added for config generation with/without project_dir
- All 13 e2e tests pass
