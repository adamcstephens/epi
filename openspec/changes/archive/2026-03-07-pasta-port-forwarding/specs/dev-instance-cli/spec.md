## ADDED Requirements

### Requirement: Up reports SSH connection details after successful launch
After a successful `epi up`, the CLI SHALL print the host port forwarded to the VM's SSH port so the user can connect immediately.

#### Scenario: SSH port is printed on successful up
- **WHEN** `epi up dev-a --target .#dev-a` succeeds
- **THEN** the CLI prints a message indicating the forwarded SSH port
- **AND** the message includes the host port number (e.g., `SSH port: 54321`)

### Requirement: Status includes forwarded SSH port
The CLI SHALL include the forwarded SSH host port in the output of any status or inspection command that shows runtime details for a running instance.

#### Scenario: Status shows SSH port for running instance
- **WHEN** a user queries the status of running instance `dev-a`
- **THEN** the output includes the forwarded SSH host port

#### Scenario: Status omits SSH port for stopped instance
- **WHEN** a user queries the status of stopped instance `dev-a`
- **THEN** no SSH port is shown (no runtime metadata available)
