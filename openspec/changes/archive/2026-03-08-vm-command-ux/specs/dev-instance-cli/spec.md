## RENAMED Requirements

### Requirement: Up command creates or starts an instance from a target
FROM: Up command creates or starts an instance from a target
TO: Launch command creates or starts an instance from a target

### Requirement: Lifecycle commands operate on instance identity
FROM: Lifecycle commands operate on instance identity
TO: Lifecycle commands operate on instance identity

## MODIFIED Requirements

### Requirement: Launch command creates or starts an instance from a target
The CLI SHALL provide a `launch` command that accepts an optional positional instance name and a required `--target <flake#config>` option. If the instance name is omitted, the CLI MUST use `default` as the instance name.

#### Scenario: Explicit instance name provided
- **WHEN** a user runs `epi launch dev-a --target .#dev-a`
- **THEN** the CLI resolves instance name `dev-a`
- **AND** the CLI resolves target `.#dev-a`

#### Scenario: Instance name omitted
- **WHEN** a user runs `epi launch --target github:org/repo#dev`
- **THEN** the CLI resolves instance name `default`
- **AND** the CLI resolves target `github:org/repo#dev`

### Requirement: Lifecycle commands operate on instance identity
The CLI SHALL treat lifecycle commands as operating on instance identity, not on target identity. The commands `stop`, `start`, `rebuild`, `ssh`, and `logs` SHALL accept an optional positional instance name and MUST default to `default` when omitted.

#### Scenario: Explicit lifecycle target
- **WHEN** a user runs `epi stop dev-a`
- **THEN** the CLI selects instance `dev-a` for shutdown

#### Scenario: Implicit default lifecycle target
- **WHEN** a user runs `epi ssh`
- **THEN** the CLI selects instance `default`

### Requirement: Missing default instance returns clear guidance
If a lifecycle command is invoked without an instance name and `default` does not exist, the CLI MUST fail with a clear message explaining how to create `default` or specify another instance.

#### Scenario: Default missing on lifecycle command
- **WHEN** a user runs `epi status` and no `default` instance exists
- **THEN** the CLI exits non-zero
- **AND** the error message mentions `default` was not found
- **AND** the error message suggests running `epi launch --target <flake#config>` or passing an instance name

### Requirement: Launch reports SSH connection details after successful launch
After a successful `epi launch`, the CLI SHALL print the host port forwarded to the VM's SSH port so the user can connect immediately.

#### Scenario: SSH port is printed on successful launch
- **WHEN** `epi launch dev-a --target .#dev-a` succeeds
- **THEN** the CLI prints a message indicating the forwarded SSH port
- **AND** the message includes the host port number (e.g., `SSH port: 54321`)
