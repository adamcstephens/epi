## MODIFIED Requirements

### Requirement: CLI exposes instance inventory
The CLI SHALL provide a `list` command that outputs known instance names, their associated targets, running status, and SSH port. The output SHALL be a four-column table with headers `INSTANCE`, `TARGET`, `STATUS`, and `SSH`. The STATUS column SHALL show `running` if the instance's systemd unit is active, or `stopped` otherwise. The SSH column SHALL show the forwarded host port number if the instance is running and has an SSH port, or `-` otherwise.

#### Scenario: Multiple instances with mixed running state
- **WHEN** a user runs `epi list` with instances `dev-a` (running, SSH port 54321) and `qa-1` (stopped)
- **THEN** the output includes headers `INSTANCE  TARGET  STATUS  SSH`
- **AND** `dev-a` row shows `running` in STATUS and `54321` in SSH
- **AND** `qa-1` row shows `stopped` in STATUS and `-` in SSH

#### Scenario: All instances stopped
- **WHEN** a user runs `epi list` and all instances are stopped
- **THEN** every row shows `stopped` in STATUS and `-` in SSH

#### Scenario: Instance has runtime but systemd unit is no longer active
- **WHEN** an instance has a `runtime` field in state.json but `systemctl --user is-active` reports inactive
- **THEN** the STATUS column shows `stopped`
- **AND** the SSH column shows `-`

### Requirement: Status includes forwarded SSH port
The `epi status` command SHALL display instance details in a labeled field format. The output SHALL include the instance name, target, and running status. When the instance is running with runtime metadata, the output SHALL additionally include SSH port, serial socket path, disk path, and unit ID.

#### Scenario: Status shows full runtime details for running instance
- **WHEN** a user runs `epi status dev-a` and `dev-a` is running with SSH port 54321
- **THEN** the output shows `Instance: dev-a`
- **AND** the output shows `Target: .#dev-a`
- **AND** the output shows `Status: running`
- **AND** the output shows `SSH port: 54321`

#### Scenario: Status shows minimal info for stopped instance
- **WHEN** a user runs `epi status dev-a` and `dev-a` is stopped
- **THEN** the output shows `Instance: dev-a`
- **AND** the output shows `Target: .#dev-a`
- **AND** the output shows `Status: stopped`
- **AND** no SSH port, serial socket, or disk path lines are shown
