## Purpose
Define how `epi up` resolves a target, launches a VM, and reports or persists state across success and failure paths.

## Requirements

### Requirement: Up provisions a VM from the requested target
The `epi up` command SHALL evaluate the provided `--target <flake-ref>#<config-name>` and SHALL attempt to provision and start a cloud-hypervisor VM for the resolved instance using coherent launch inputs produced by that target evaluation. The VM SHALL be launched with pasta-backed networking instead of TAP-based networking. When a valid descriptor cache exists for the target and all artifact paths are present on disk, the CLI SHALL skip nix eval and nix build and use the cached descriptor directly. When relaunching over a stale instance, the CLI SHALL terminate any tracked pasta process from the prior runtime before starting a new one.

#### Scenario: Named instance is provisioned
- **WHEN** a user runs `epi up dev-a --target .#dev-a`
- **THEN** the CLI evaluates target `.#dev-a` (or uses a valid cache)
- **AND** the CLI invokes cloud-hypervisor using the resolved VM launch inputs with pasta networking
- **AND** the CLI reports provisioning success for instance `dev-a`

#### Scenario: Default instance is provisioned
- **WHEN** a user runs `epi up --target github:org/repo#dev`
- **THEN** the CLI resolves instance name `default`
- **AND** the CLI invokes cloud-hypervisor for the resolved target using coherent launch inputs from one evaluation result with pasta networking
- **AND** the CLI reports provisioning success for instance `default`

#### Scenario: Stale pasta process is terminated before relaunch
- **WHEN** a user runs `epi up dev-a --target .#dev-a`
- **AND** instance `dev-a` has a stale runtime entry with a pasta PID
- **THEN** the CLI sends SIGTERM to the stale pasta process before launching the new VM
- **AND** the CLI successfully provisions the new instance

#### Scenario: Cached descriptor is used when valid
- **WHEN** a user runs `epi up --target .#dev-a` and a valid descriptor cache exists with all paths on disk
- **THEN** the CLI skips nix eval
- **AND** the CLI invokes cloud-hypervisor using the cached descriptor

### Requirement: Up accepts --rebuild to force re-evaluation
The `epi up` command SHALL accept a `--rebuild` flag that bypasses the descriptor cache, forces nix eval and nix build, and updates the cache with the fresh result before launching.

#### Scenario: --rebuild forces eval on cached target
- **WHEN** a user runs `epi up --target .#foo --rebuild`
- **THEN** the descriptor cache for `.#foo` is invalidated
- **AND** nix eval is run unconditionally
- **AND** the resolved descriptor is cached before VM launch

### Requirement: Up persists state only after successful provisioning
The CLI SHALL persist instance-to-target metadata only if VM provisioning succeeds.

#### Scenario: Provisioning succeeds
- **WHEN** `epi up qa-1 --target .#qa`
- **THEN** the command exits zero
- **AND** `qa-1` is stored with target `.#qa`

#### Scenario: Provisioning fails
- **WHEN** cloud-hypervisor launch fails during `epi up qa-1 --target .#qa`
- **THEN** the command exits non-zero
- **AND** the CLI does not persist or update instance `qa-1`

### Requirement: Up returns actionable stage-specific errors
When provisioning fails, `epi up` MUST return an error message that identifies the failure stage and the relevant context.

#### Scenario: Target evaluation fails
- **WHEN** target evaluation fails for `epi up dev-a --target .#dev-a`
- **THEN** the command exits non-zero
- **AND** the error states that target resolution failed
- **AND** the error includes the failing target string

#### Scenario: VM launch fails
- **WHEN** cloud-hypervisor returns a non-zero exit for `epi up dev-a --target .#dev-a`
- **THEN** the command exits non-zero
- **AND** the error states that VM launch failed
- **AND** the error includes the cloud-hypervisor exit status

#### Scenario: pasta binary is missing
- **WHEN** the pasta binary is not found on PATH and `EPI_PASTA_BIN` is not set
- **THEN** `epi up` exits non-zero
- **AND** the error states that pasta was not found
- **AND** the error suggests installing the `passt` package or setting `EPI_PASTA_BIN`

#### Scenario: pasta socket is unavailable
- **WHEN** pasta is started but its vhost-user socket does not become available within the timeout
- **THEN** `epi up` exits non-zero
- **AND** the error states that the pasta socket did not become ready
- **AND** cloud-hypervisor is not started

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
The `epi up` command SHALL emit concise, user-visible progress messages for major setup stages so users can distinguish active work from a stalled command.

#### Scenario: Target evaluation and build stage is visible
- **WHEN** a user runs `epi up --target .#manual-test` and target evaluation/build takes noticeable time
- **THEN** the CLI outputs a stage message indicating target evaluation/build has started
- **AND** the CLI outputs a stage transition or completion message before moving to launch preparation

#### Scenario: VM launch stage is visible
- **WHEN** a user runs `epi up dev-a --target .#dev-a` and provisioning proceeds to launch
- **THEN** the CLI outputs a stage message indicating VM launch has started
- **AND** the CLI outputs the existing success/failure outcome with stage-appropriate context

#### Scenario: Progress messages remain concise
- **WHEN** a user runs `epi up` for any valid target
- **THEN** progress output is limited to major stage transitions rather than verbose per-command logs
- **AND** the additional output remains human-readable without requiring verbose mode
