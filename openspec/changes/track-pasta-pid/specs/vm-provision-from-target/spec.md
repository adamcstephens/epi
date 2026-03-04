## MODIFIED Requirements

### Requirement: Up provisions a VM from the requested target
The `epi up` command SHALL evaluate the provided `--target <flake-ref>#<config-name>` and SHALL attempt to provision and start a cloud-hypervisor VM for the resolved instance. When relaunching over a stale instance, the CLI SHALL terminate any tracked pasta process from the prior runtime before starting a new one.

#### Scenario: Named instance is provisioned
- **WHEN** a user runs `epi up dev-a --target .#dev-a`
- **THEN** the CLI evaluates target `.#dev-a`
- **AND** the CLI invokes cloud-hypervisor using the resolved VM launch inputs with pasta networking
- **AND** the CLI reports provisioning success for instance `dev-a`

#### Scenario: Default instance is provisioned
- **WHEN** a user runs `epi up --target github:org/repo#dev`
- **THEN** the CLI resolves instance name `default`
- **AND** the CLI invokes cloud-hypervisor for the resolved target with pasta networking
- **AND** the CLI reports provisioning success for instance `default`

#### Scenario: Stale pasta process is terminated before relaunch
- **WHEN** a user runs `epi up dev-a --target .#dev-a`
- **AND** instance `dev-a` has a stale runtime entry with a pasta PID
- **THEN** the CLI sends SIGTERM to the stale pasta process before launching the new VM
- **AND** the CLI successfully provisions the new instance
