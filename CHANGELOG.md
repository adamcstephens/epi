# Changelog

## [Unreleased]

### Changed
- NixOS module: Filter `configuredUsers` to only include normal users (`isNormalUser`), excluding system accounts (nixbld, nobody, sshd, etc.)
- `list`/`info`: Replace home directory prefix with `~` in target paths
- `list`/`info`: Replace manual text formatting with comfy-table for aligned column output
- `list`: Sort project-scoped instances before global ones
- `info`: Replace runtime file paths section with service unit tree and uptime display
- `info`: Add `state:` row to instance section showing state directory path
- Unify all systemd unit name generation through `instance_store::unit_name()`, ensuring consistent escaping for passt and virtiofsd helpers
- Reduce shutdown timeout from 15s to 10s before force-killing the VM

### Fixed
- `list`: Remove `ContentArrangement::Dynamic` so table renders correctly without a TTY (fixes nix build test failures)

### Added
- Print informational message when project config is detected during launch (e.g. `using project config: ~/projects/foo/.epi/config.toml`)
- `upgrade`: Live-upgrade a running instance to a new configuration without rebuilding the disk image. Supports `--mode switch` (default, live activation) and `--mode boot` (reboot with new kernel/initrd)
- `ssh`: Add `nix_copy_closure` and `run_on_guest` library functions for copying nix store closures and running commands on instances via SSH
- NixOS module: Add `@wheel` to `trusted-users` in guest nix config to allow `nix copy` from host

## [0.7.1] - 2026-03-18

### Added
- Enable virtio memory balloon device on all VMs with `deflate_on_oom` and `free_page_reporting` for host memory reclaim
- `ssh`: Auto-cd into project directory when connecting to a project instance via `RemoteCommand`
- `hooks`: Pass `EPI_PROJECT_DIR` environment variable to post-launch and pre-stop hooks
- Create nix GC roots for instance store paths (kernel, disk, initrd, hooks) to prevent `nix-collect-garbage` from breaking stopped instances
- Store resolved descriptor in state.json for self-contained instance state

### Fixed
- `ssh`: Pass `RemoteCommand`/`RequestTTY` as CLI flags instead of writing them into the SSH config file, fixing `exec`, `cp`, and SSH health checks that were broken by the config-level `RemoteCommand`
- `info`: Display disk size as GiB (e.g. "40 GiB") instead of raw qemu-img suffix, and label ssh port field as `ssh_port`
- Canonicalize `state_dir()` and `cache_dir()` to absolute paths when env vars contain relative paths
- `project_dir()` now returns the project root instead of the `.epi/` subdirectory

### Changed
- `launch`: Rename "Resolving" step to "Evaluating" for consistency with actual operation
- `launch`: Capitalize first word of all status messages consistently
- `launch`: Drop SSH port from ready messages
- `launch`: Show cached/present store paths (kernel, initrd, image) alongside build steps
- `launch`: Show elapsed time on completed step lines with sub-second granularity
- Show only filenames during `cp` instead of per-file rsync progress summaries
- `info`: Show cpu/memory in resources, ssh port only (not full command), ssh_config path, full slice name, console log path, and tilde-shorten all paths

## [0.6.0] - 2026-03-15

### Changed
- **Breaking:** Rename `--no-wait` flag to `--no-provision` (and `EPI_NO_WAIT` env var to `EPI_NO_PROVISION`)
- Show discrete build steps (evaluate, kernel, initrd, image) with grouped spinners instead of a single opaque "Provisioning" spinner

## [0.5.0] - 2026-03-14

### Changed
- **Breaking:** Rename `status` subcommand to `info` with expanded output (resources, mounts, project dir, SSH command, grouped sections)
- Switch shell completions to dynamic clap_complete for instance name tab-completion
- Persist all resolved VM params (cpus, memory, disk_size, port_specs) in instance state; start/rebuild read stored values directly

## [0.4.1] - 2026-03-14

### Fixed
- Fix virtiofsd mount permission issues by switching to `--sandbox none` and removing uid/gid mapping flags

## [0.4.0] - 2026-03-14

### Added
- Multiple port mapping support
- Shell tab completion for fish, bash, and zsh
- `--cpus` and `--memory` CLI flags with config file support
- Configurable default instance name
- SSH config generation and `ssh-config` subcommand
- Per-instance SSH host key recording with strict host key checking
- Console scrollback: dump recent console.log on attach with control char stripping
- Auto-mount project directory for project-local instances
- Project-scoped instance listing
- `epi init` command for interactive project initialization
- Nested virtualization support

### Changed
- Console capture via virtio-console: replaced in-process thread with CH `--console file=`
- Extracted SSH module from main codebase
- Merge user and project mount configs with union semantics
- Optimized VM boot: networkd, disable firewall, blacklist modules, disable getty
- Patched cloud-hypervisor for project needs
- Moved flakes/nix-command to non extra-experimental
- Split main.rs command handlers into `commands/` module (lifecycle, access, info, init)
- `rm` reports when instance doesn't exist instead of silent success

### Fixed
- Graceful VM shutdown: absolute shebang, stop VM service before slice, non-fatal shutdown-vmm
- virtiofs file creation in user namespaces: map host uid/gid to namespace root
- All clippy warnings

## [0.3.0] - 2026-03-13

### Added
- `epi cp` command for rsync file copy to/from instances
- Styled CLI output with spinners, colored status, and error formatting
- Graceful VM shutdown via cloud-hypervisor API socket
- Release recipe

### Changed
- Extracted cloud-hypervisor module from vm_launch
- Stripped env forwarding from systemd-run calls
- Switched console ctrl-t q handling to avoid blocking unknown keys
- Disabled log rotation

### Fixed
- ExecStop shutdown by generating a script with absolute paths
- Start/stop breakage from relative mount in VM
- Shutdown reliability improvements

## [0.2.2] - 2026-03-12

Initial tagged release.
