## MODIFIED Requirements

### Requirement: Up provisions a VM from the requested target
The `epi up` command SHALL evaluate the provided `--target <flake-ref>#<config-name>` and SHALL attempt to provision and start a cloud-hypervisor VM for the resolved instance using coherent launch inputs produced by that target evaluation.

#### Scenario: Named instance is provisioned
- **WHEN** a user runs `epi up dev-a --target .#dev-a`
- **THEN** the CLI evaluates target `.#dev-a`
- **AND** the CLI invokes cloud-hypervisor using launch inputs that were resolved from that evaluation
- **AND** the CLI reports provisioning success for instance `dev-a`

#### Scenario: Default instance is provisioned
- **WHEN** a user runs `epi up --target github:org/repo#dev`
- **THEN** the CLI resolves instance name `default`
- **AND** the CLI invokes cloud-hypervisor for the resolved target using coherent launch inputs from one evaluation result
- **AND** the CLI reports provisioning success for instance `default`

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
