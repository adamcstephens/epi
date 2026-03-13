## MODIFIED Requirements

### Requirement: Launch command creates or starts an instance from a target
The CLI SHALL provide a `launch` command that accepts an optional positional instance name and an optional `--target <flake#config>` option. If the instance name is omitted, the CLI MUST use `default` as the instance name. If `--target` is omitted, the CLI SHALL look for a `target` value in the project config file (`.epi/config.toml`). If neither CLI nor config provides a target, the CLI MUST exit non-zero with an error message explaining both ways to provide a target. The command SHALL accept `--no-wait` to skip SSH polling and `--wait-timeout` to configure the SSH wait duration.

During launch, the CLI SHALL show step-based progress output on stderr: a spinner during provisioning with elapsed time, and a spinner during SSH wait with elapsed time. On completion, the CLI SHALL display a success message with the SSH port. When `--console` is active, the CLI SHALL skip spinners (to avoid corrupting raw terminal mode) and use plain text messages instead.

#### Scenario: Explicit instance name provided
- **WHEN** a user runs `epi launch dev-a --target .#dev-a`
- **THEN** the CLI resolves instance name `dev-a`
- **AND** the CLI resolves target `.#dev-a`

#### Scenario: Instance name omitted
- **WHEN** a user runs `epi launch --target github:org/repo#dev`
- **THEN** the CLI resolves instance name `default`
- **AND** the CLI resolves target `github:org/repo#dev`

#### Scenario: --no-wait flag skips SSH polling
- **WHEN** a user runs `epi launch dev-a --target .#dev-a --no-wait`
- **THEN** the command returns after the VM process is verified running
- **AND** no SSH polling is performed

#### Scenario: --wait-timeout configures wait duration
- **WHEN** a user runs `epi launch --target .#dev-a --wait-timeout 60`
- **THEN** the SSH polling phase uses a 60-second timeout instead of the default

#### Scenario: Target from config file when --target omitted
- **WHEN** `.epi/config.toml` contains `target = ".#dev"`
- **AND** a user runs `epi launch` without `--target`
- **THEN** the CLI resolves target `.#dev`

#### Scenario: No target from CLI or config
- **WHEN** no `.epi/config.toml` exists or it has no `target` key
- **AND** a user runs `epi launch` without `--target`
- **THEN** the CLI exits non-zero
- **AND** the error message explains that `--target` is required or a target can be set in `.epi/config.toml`

#### Scenario: Progress spinners during launch
- **WHEN** a user runs `epi launch` in an interactive terminal
- **THEN** stderr shows a spinner during provisioning with elapsed time
- **AND** stderr shows a spinner during SSH wait with elapsed time
- **AND** on success, a "✓" prefixed message shows the instance is ready with the SSH port

#### Scenario: Plain progress with --console flag
- **WHEN** a user runs `epi launch --console`
- **THEN** the SSH wait in the background thread uses plain `eprintln!` messages instead of spinners

### Requirement: CLI exposes instance inventory
The CLI SHALL provide a `list` command that outputs known instance names, their associated targets, running status, and SSH port. The output SHALL be a four-column table with headers `INSTANCE`, `TARGET`, `STATUS`, and `SSH`. The STATUS column SHALL show `● running` (green dot) if the instance's systemd unit is active, or `○ stopped` (dim dot) otherwise. The SSH column SHALL show the forwarded host port as `127.0.0.1:<port>` if the instance is running and has an SSH port, or `—` (em dash) otherwise.

#### Scenario: Multiple instances with mixed running state
- **WHEN** a user runs `epi list` with instances `dev-a` (running, SSH port 54321) and `qa-1` (stopped)
- **THEN** the output includes headers `INSTANCE  TARGET  STATUS  SSH`
- **AND** `dev-a` row shows `● running` in STATUS and `127.0.0.1:54321` in SSH
- **AND** `qa-1` row shows `○ stopped` in STATUS and `—` in SSH

#### Scenario: All instances stopped
- **WHEN** a user runs `epi list` and all instances are stopped
- **THEN** every row shows `○ stopped` in STATUS and `—` in SSH

#### Scenario: Instance has runtime but systemd unit is no longer active
- **WHEN** an instance has a `runtime` field in state.json but `systemctl --user is-active` reports inactive
- **THEN** the STATUS column shows `○ stopped`
- **AND** the SSH column shows `—`

### Requirement: Status includes forwarded SSH port
The `epi status` command SHALL display instance details in a labeled field format. The output SHALL include the instance name (bold), target, and running status with a colored dot indicator. When the instance is running with runtime metadata, the output SHALL additionally include SSH port, serial socket path, disk path, and unit ID.

#### Scenario: Status shows full runtime details for running instance
- **WHEN** a user runs `epi status dev-a` and `dev-a` is running with SSH port 54321
- **THEN** the output shows `instance:  dev-a` with the name in bold
- **AND** the output shows `target:    .#dev-a`
- **AND** the output shows `status:    ● running` with the dot in green
- **AND** the output shows `ssh port:  54321`
- **AND** the output shows `serial:`, `disk:`, and `unit id:` fields

#### Scenario: Status shows runtime fields even when stopped
- **WHEN** a user runs `epi status dev-a` and `dev-a` is stopped but has stored runtime metadata
- **THEN** the output shows `instance:  dev-a` with the name in bold
- **AND** the output shows `target:    .#dev-a`
- **AND** the output shows `status:    ○ stopped` with the dot dimmed
- **AND** runtime fields (ssh port, serial, disk, unit id) are still shown if runtime metadata exists

### Requirement: Launch reports SSH connection details after successful launch
After a successful `epi launch`, the CLI SHALL print the host port forwarded to the VM's SSH port as part of the success step message so the user can connect immediately.

#### Scenario: SSH port is printed on successful launch
- **WHEN** `epi launch dev-a --target .#dev-a` succeeds
- **THEN** the CLI prints a "✓" prefixed message indicating the instance is ready with the SSH port number
