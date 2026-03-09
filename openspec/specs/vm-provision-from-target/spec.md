## Purpose
Define how `epi launch` resolves a target, launches a VM, and reports or persists state across success and failure paths.

## Requirements

### Requirement: Up provisions a VM from the requested target
The `epi launch` command SHALL evaluate the provided `--target <flake-ref>#<config-name>` and SHALL attempt to provision and start a cloud-hypervisor VM for the resolved instance using coherent launch inputs produced by that target evaluation. The VM SHALL be launched with passt-backed networking instead of TAP-based networking. When a valid descriptor cache exists for the target and all artifact paths are present on disk, the CLI SHALL skip nix eval and nix build and use the cached descriptor directly. When relaunching over a stale instance, the CLI SHALL terminate any tracked systemd units from the prior runtime before starting a new one. The target resolver (whether built-in `nix eval --json` or custom via `EPI_TARGET_RESOLVER_CMD`) MUST produce JSON output containing the descriptor fields.

#### Scenario: Named instance is provisioned
- **WHEN** a user runs `epi launch dev-a --target .#dev-a`
- **THEN** the CLI evaluates target `.#dev-a` (or uses a valid cache)
- **AND** the CLI invokes cloud-hypervisor using the resolved VM launch inputs with passt networking
- **AND** the CLI reports provisioning success for instance `dev-a`

#### Scenario: Default instance is provisioned
- **WHEN** a user runs `epi launch --target github:org/repo#dev`
- **THEN** the CLI resolves instance name `default`
- **AND** the CLI invokes cloud-hypervisor for the resolved target using coherent launch inputs from one evaluation result with passt networking
- **AND** the CLI reports provisioning success for instance `default`

#### Scenario: Stale systemd units are terminated before relaunch
- **WHEN** a user runs `epi launch dev-a --target .#dev-a`
- **AND** instance `dev-a` has a stale runtime entry with systemd units
- **THEN** the CLI stops the stale systemd units before launching the new VM
- **AND** the CLI successfully provisions the new instance

#### Scenario: Cached descriptor is used when valid
- **WHEN** a user runs `epi launch --target .#dev-a` and a valid descriptor cache exists with all paths on disk
- **THEN** the CLI skips nix eval
- **AND** the CLI invokes cloud-hypervisor using the cached descriptor

#### Scenario: Custom target resolver must output JSON
- **WHEN** `EPI_TARGET_RESOLVER_CMD` is set to a custom script
- **THEN** the script MUST output a JSON object with keys: `kernel`, `disk`, `initrd`, `cmdline`, `cpus`, `memory_mib`, `configuredUsers`
- **AND** the CLI SHALL parse the output as JSON using the same parser as `nix eval --json`

### Requirement: Up accepts --rebuild to force re-evaluation
The `epi launch` command SHALL accept a `--rebuild` flag that bypasses the descriptor cache, forces nix eval and nix build, and updates the cache with the fresh result before launching.

#### Scenario: --rebuild forces eval on cached target
- **WHEN** a user runs `epi launch --target .#foo --rebuild`
- **THEN** the descriptor cache for `.#foo` is invalidated
- **AND** nix eval is run unconditionally
- **AND** the resolved descriptor is cached before VM launch

### Requirement: Up persists state only after successful provisioning
The CLI SHALL persist instance-to-target metadata only if VM provisioning succeeds.

#### Scenario: Provisioning succeeds
- **WHEN** `epi launch qa-1 --target .#qa`
- **THEN** the command exits zero
- **AND** `qa-1` is stored with target `.#qa`

#### Scenario: Provisioning fails
- **WHEN** cloud-hypervisor launch fails during `epi launch qa-1 --target .#qa`
- **THEN** the command exits non-zero
- **AND** the CLI does not persist or update instance `qa-1`

### Requirement: Up returns actionable stage-specific errors
When provisioning fails, `epi launch` MUST return an error message that identifies the failure stage and the relevant context.

#### Scenario: Target evaluation fails
- **WHEN** target evaluation fails for `epi launch dev-a --target .#dev-a`
- **THEN** the command exits non-zero
- **AND** the error states that target resolution failed
- **AND** the error includes the failing target string

#### Scenario: VM launch fails
- **WHEN** cloud-hypervisor returns a non-zero exit for `epi launch dev-a --target .#dev-a`
- **THEN** the command exits non-zero
- **AND** the error states that VM launch failed
- **AND** the error includes the cloud-hypervisor exit status

#### Scenario: pasta binary is missing
- **WHEN** the pasta binary is not found on PATH and `EPI_PASTA_BIN` is not set
- **THEN** `epi launch` exits non-zero
- **AND** the error states that pasta was not found
- **AND** the error suggests installing the `passt` package or setting `EPI_PASTA_BIN`

#### Scenario: pasta socket is unavailable
- **WHEN** pasta is started but its vhost-user socket does not become available within the timeout
- **THEN** `epi launch` exits non-zero
- **AND** the error states that the pasta socket did not become ready
- **AND** cloud-hypervisor is not started

#### Scenario: seed ISO generation fails due to missing genisoimage
- **WHEN** `genisoimage` is not found on `$PATH` and `EPI_GENISOIMAGE_BIN` is not set
- **THEN** `epi launch` exits non-zero
- **AND** the error states that `genisoimage` was not found
- **AND** the error suggests installing `cdrkit` or setting `EPI_GENISOIMAGE_BIN`

#### Scenario: seed ISO generation fails due to genisoimage error
- **WHEN** `genisoimage` exits non-zero during seed ISO creation
- **THEN** `epi launch` exits non-zero
- **AND** the error includes the stderr output from genisoimage

#### Scenario: virtiofsd binary is missing when mounts are requested
- **WHEN** `--mount` is passed and `virtiofsd` is not found on `$PATH` and `EPI_VIRTIOFSD_BIN` is not set
- **THEN** `epi launch` exits non-zero
- **AND** the error states that `virtiofsd` was not found
- **AND** the error suggests installing the `virtiofsd` package or setting `EPI_VIRTIOFSD_BIN`

#### Scenario: virtiofsd fails to start
- **WHEN** `virtiofsd` starts but exits non-zero
- **THEN** `epi launch` exits non-zero
- **AND** the error includes the stderr output from virtiofsd

#### Scenario: virtiofsd socket does not appear
- **WHEN** virtiofsd is started but its socket does not appear within the timeout
- **THEN** `epi launch` exits non-zero
- **AND** the error states that the virtiofsd socket did not become ready

#### Scenario: mount path is not a directory
- **WHEN** a path passed to `--mount` is not a directory (e.g. a regular file or nonexistent path)
- **THEN** `epi launch` exits non-zero
- **AND** the error states that the path is not a directory
- **AND** the error notes that virtiofsd only supports directory sharing

#### Scenario: disk overlay resize fails
- **WHEN** `qemu-img resize` exits non-zero during disk overlay preparation
- **THEN** `epi launch` exits non-zero
- **AND** the error states that disk resize failed
- **AND** the error includes the stderr output from qemu-img

#### Scenario: disk overlay copy fails
- **WHEN** copying the Nix-store disk to the overlay path fails (e.g. permission error, full disk)
- **THEN** `epi launch` exits non-zero
- **AND** the error states that overlay preparation failed
- **AND** the error includes the OS error details

#### Scenario: disk is already locked by another running instance
- **WHEN** `epi launch qa-1 --target .#qa` resolves a disk already held by running instance `dev-a`
- **THEN** the command exits non-zero before launching any processes
- **AND** the error names `dev-a` as the current holder of the disk lock
- **AND** the error includes `dev-a`'s `unit_id`
- **AND** the error suggests stopping `dev-a` before retrying

#### Scenario: systemd user session is unavailable
- **WHEN** `systemd-run --user` fails because no user session is active (e.g. running via cron or SSH without lingering)
- **THEN** `epi launch` exits non-zero
- **AND** the error states that the systemd user session is unavailable
- **AND** the error suggests running `loginctl enable-linger <user>`

#### Scenario: VM exits immediately after systemd-run returns
- **WHEN** `systemd-run` returns exit 0 (unit created) but the VM service is no longer active after a brief settle period
- **THEN** `epi launch` exits non-zero
- **AND** the error states that the VM exited immediately after start

### Requirement: Up validates required launch inputs before invoking cloud-hypervisor
Before launching cloud-hypervisor, the CLI MUST validate that all required launch descriptor fields are present, refer to accessible artifacts, and form a coherent boot tuple.

#### Scenario: Required artifact is missing
- **WHEN** target resolution returns a descriptor missing a required artifact path
- **THEN** the command exits non-zero
- **AND** the error identifies the missing launch input
- **AND** cloud-hypervisor is not invoked

#### Scenario: Launch inputs are not coherent
- **WHEN** target resolution returns kernel/initrd paths that do not correspond to the resolved disk artifact set
- **THEN** the command exits non-zero before hypervisor launch
- **AND** the error states that launch inputs are not coherent
- **AND** the error guidance points to fixing or rebuilding target outputs instead of reusing an external mutable disk image

### Requirement: Up reports setup stage progress during provisioning
The `epi launch` command SHALL emit concise, user-visible progress messages for major setup stages so users can distinguish active work from a stalled command.

#### Scenario: Target evaluation and build stage is visible
- **WHEN** a user runs `epi launch --target .#manual-test` and target evaluation/build takes noticeable time
- **THEN** the CLI outputs a stage message indicating target evaluation/build has started
- **AND** the CLI outputs a stage transition or completion message before moving to launch preparation

#### Scenario: VM launch stage is visible
- **WHEN** a user runs `epi launch dev-a --target .#dev-a` and provisioning proceeds to launch
- **THEN** the CLI outputs a stage message indicating VM launch has started
- **AND** the CLI outputs the existing success/failure outcome with stage-appropriate context

#### Scenario: Progress messages remain concise
- **WHEN** a user runs `epi launch` for any valid target
- **THEN** progress output is limited to major stage transitions rather than verbose per-command logs
- **AND** the additional output remains human-readable without requiring verbose mode
