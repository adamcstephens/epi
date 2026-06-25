# Changelog

## [Unreleased]

### Added
- `ssh`/`exec`/`cp`: When the instance exists but is stopped, prompt to start it before connecting. Pass `--start` to start it without prompting (e.g. in scripts); with no TTY and no `--start`, the command errors and points at `epi start`

### Changed
- Mounts under the host home directory are now also reachable at the guest home path. On macOS (host home `/Users/<user>`, guest home `/home/<user>`) the share mounts at the real host path and is bind-mounted into the guest home, so `~/project` resolves inside the guest
- NixOS module: Replace systemd-timesyncd with chrony for guest time sync. The guest clock now recovers immediately after host sleep/wake: chrony steps any large offset (`makestep 1.0 -1`) and, on cloud-hypervisor/KVM, syncs directly off the host clock via the `ptp_kvm` PHC refclock without needing the network

## [0.9.0] - 2026-06-07

### Added
- **macOS support (Apple Silicon)**: epi now runs on macOS using Virtualization.framework. `launch`, `ssh`, `exec`, `console`, `console-log`, and `stop` all work against an aarch64 NixOS guest, with the same UX as Linux. Requires an aarch64 `nixosConfiguration` (VZ runs aarch64 guests only); nix-built binaries are codesigned automatically, and `just sign` signs local dev builds.
- Hooks receive `EPI_SSH_HOST` (the guest's address) alongside `EPI_SSH_PORT`, so hook scripts can reach the guest without assuming `localhost`
- `ssh_extra_config`: Allow custom SSH config lines in user/project config (e.g. `LocalForward`, `ForwardAgent`), appended to generated SSH config for each instance
- Print informational message when project config is detected during launch (e.g. `using project config: ~/projects/foo/.epi/config.toml`)
- `upgrade`: Live-upgrade a running instance to a new configuration without rebuilding the disk image. Supports `--mode switch` (default, live activation) and `--mode boot` (reboot with new kernel/initrd)
- NixOS module: Add `@wheel` to `trusted-users` in guest nix config to allow `nix copy` from host

### Changed
- `stop --force` / `rm --force`: Skip ACPI shutdown and SIGKILL the VM main process directly for sub-second termination; pre-stop hooks are skipped under `--force`
- `start`: Always use the descriptor stored at launch — no re-resolution, no `Using stored descriptor` info message
- `upgrade`: Display store paths for toplevel, kernel, and initrd in preparation output, matching `launch` formatting
- NixOS module: Cap per-user systemd manager `DefaultTimeoutStopSec` at 5s so a stuck user service can't block `multi-user.target` shutdown for the full 90s
- NixOS module: Filter `configuredUsers` to only include normal users (`isNormalUser`), excluding system accounts (nixbld, nobody, sshd, etc.)
- `list`/`info`: Replace home directory prefix with `~` in target paths
- `list`/`info`: Replace manual text formatting with comfy-table for aligned column output
- `list`: Sort project-scoped instances before global ones
- `info`: Replace runtime file paths section with service unit tree and uptime display
- `info`: Add `state:` row to instance section showing state directory path
- Reduce shutdown timeout from 15s to 10s before force-killing the VM

### Fixed
- `stop` / `launch`: When clearing stale runtime, also stop leftover passt/virtiofsd units and remove stale sockets — a crashed VM could leave helpers holding `passt.sock`, blocking subsequent `start`
- `upgrade --mode boot`: Skip `switch-to-configuration boot` — the guest has no bootloader, so the new generation activates by rewriting kernel/initrd/cmdline in the descriptor and rebooting the VM
- `list`: Remove `ContentArrangement::Dynamic` so table renders correctly without a TTY (fixes nix build test failures)
- Fix mount paths under user's home creating intermediate directories owned by root instead of the user

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
