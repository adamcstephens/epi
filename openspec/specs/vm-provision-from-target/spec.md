## Purpose
Define how `epi up` resolves a target, launches a VM, and reports or persists state across success and failure paths.

## Requirements

### Requirement: Up provisions a VM from the requested target
The `epi up` command SHALL evaluate the provided `--target <flake-ref>#<config-name>` and SHALL attempt to provision and start a cloud-hypervisor VM for the resolved instance.

#### Scenario: Named instance is provisioned
- **WHEN** a user runs `epi up dev-a --target .#dev-a`
- **THEN** the CLI evaluates target `.#dev-a`
- **AND** the CLI invokes cloud-hypervisor using the resolved VM launch inputs
- **AND** the CLI reports provisioning success for instance `dev-a`

#### Scenario: Default instance is provisioned
- **WHEN** a user runs `epi up --target github:org/repo#dev`
- **THEN** the CLI resolves instance name `default`
- **AND** the CLI invokes cloud-hypervisor for the resolved target
- **AND** the CLI reports provisioning success for instance `default`

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

### Requirement: Up validates required launch inputs before invoking cloud-hypervisor
Before launching cloud-hypervisor, the CLI MUST validate that all required launch descriptor fields are present and refer to accessible artifacts.

#### Scenario: Required artifact is missing
- **WHEN** target resolution returns a descriptor missing a required artifact path
- **THEN** the command exits non-zero
- **AND** the error identifies the missing launch input
- **AND** cloud-hypervisor is not invoked
