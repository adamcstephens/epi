## MODIFIED Requirements

### Requirement: Up provisions a VM from the requested target
The `epi up` command SHALL evaluate the provided `--target <flake-ref>#<config-name>` and SHALL attempt to provision and start a cloud-hypervisor VM for the resolved instance using coherent launch inputs produced by that target evaluation. The VM SHALL be launched with pasta-backed networking instead of TAP-based networking. When a valid descriptor cache exists for the target and all artifact paths are present on disk, the CLI SHALL skip nix eval and nix build and use the cached descriptor directly. When relaunching over a stale instance, the CLI SHALL stop the instance's systemd slice before starting new processes. Cloud-hypervisor SHALL be started as a transient systemd user service (with `ExecStopPost` for cascade shutdown). Passt and virtiofsd SHALL be started as systemd user scopes. All units SHALL be grouped under the instance's slice.

#### Scenario: Named instance is provisioned
- **WHEN** a user runs `epi up dev-a --target .#dev-a`
- **THEN** the CLI evaluates target `.#dev-a` (or uses a valid cache)
- **AND** the CLI starts cloud-hypervisor as a transient systemd user service under the instance slice
- **AND** the CLI reports provisioning success for instance `dev-a`

#### Scenario: Default instance is provisioned
- **WHEN** a user runs `epi up --target github:org/repo#dev`
- **THEN** the CLI resolves instance name `default`
- **AND** the CLI starts cloud-hypervisor as a transient systemd user service under the instance slice
- **AND** the CLI reports provisioning success for instance `default`

#### Scenario: Stale instance slice is stopped before relaunch
- **WHEN** a user runs `epi up dev-a --target .#dev-a`
- **AND** instance `dev-a` has a stale systemd slice with active units
- **THEN** the CLI stops the old instance slice before launching new processes
- **AND** the CLI successfully provisions the new instance

#### Scenario: Cached descriptor is used when valid
- **WHEN** a user runs `epi up --target .#dev-a` and a valid descriptor cache exists with all paths on disk
- **THEN** the CLI skips nix eval
- **AND** the CLI starts cloud-hypervisor using the cached descriptor

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
