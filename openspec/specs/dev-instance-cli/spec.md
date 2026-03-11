## Purpose
Define the CLI surface for managing development VM instances, including creation, lifecycle operations, and instance inventory.
## Requirements
### Requirement: Launch command creates or starts an instance from a target
The CLI SHALL provide a `launch` command that accepts an optional positional instance name and a required `--target <flake#config>` option. If the instance name is omitted, the CLI MUST use `default` as the instance name. The command SHALL accept `--no-wait` to skip SSH polling and `--wait-timeout` to configure the SSH wait duration.

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

### Requirement: Target value follows flake#config syntax
The CLI SHALL treat `--target` as a single string value in `<flake-ref>#<config-name>` form and MUST reject malformed values with actionable errors.

#### Scenario: Missing separator
- **WHEN** a user runs `epi launch dev-a --target .`
- **THEN** the CLI exits non-zero
- **AND** the error states that `--target` must use `<flake-ref>#<config-name>`

#### Scenario: Missing config name
- **WHEN** a user runs `epi launch dev-a --target .#`
- **THEN** the CLI exits non-zero
- **AND** the error states that both flake reference and config name are required

### Requirement: Lifecycle commands operate on instance identity
The CLI SHALL treat lifecycle commands as operating on instance identity, not on target identity. The commands `down`, `rebuild`, `ssh`, `exec`, and `logs` SHALL accept an optional positional instance name and MUST default to `default` when omitted.

#### Scenario: Explicit lifecycle target
- **WHEN** a user runs `epi down dev-a`
- **THEN** the CLI selects instance `dev-a` for shutdown

#### Scenario: Implicit default lifecycle target
- **WHEN** a user runs `epi ssh`
- **THEN** the CLI selects instance `default`

#### Scenario: Exec uses default instance
- **WHEN** a user runs `epi exec -- hostname`
- **THEN** the CLI selects instance `default`

### Requirement: Missing default instance returns clear guidance
If a lifecycle command is invoked without an instance name and `default` does not exist, the CLI MUST fail with a clear message explaining how to create `default` or specify another instance.

#### Scenario: Default missing on lifecycle command
- **WHEN** a user runs `epi status` and no `default` instance exists
- **THEN** the CLI exits non-zero
- **AND** the error message mentions `default` was not found
- **AND** the error message suggests running `epi launch --target <flake#config>` or passing an instance name

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

### Requirement: Launch reports SSH connection details after successful launch
After a successful `epi launch`, the CLI SHALL print the host port forwarded to the VM's SSH port so the user can connect immediately.

#### Scenario: SSH port is printed on successful launch
- **WHEN** `epi launch dev-a --target .#dev-a` succeeds
- **THEN** the CLI prints a message indicating the forwarded SSH port
- **AND** the message includes the host port number (e.g., `SSH port: 54321`)

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

### Requirement: ssh command opens an SSH session to a running instance
The `epi ssh` command SHALL resolve the instance's stored SSH port and exec into `ssh`, replacing the epi process. It SHALL not wrap or proxy the SSH connection — the user's terminal is handed directly to `ssh`.

Connection parameters:
- Host: `127.0.0.1`
- Port: the stored `ssh_port` from the instance runtime
- User: `$USER` from the environment (falls back to `user` if unset)
- `StrictHostKeyChecking=no` — VMs generate fresh host keys on each provision
- `UserKnownHostsFile=/dev/null` — prevents stale host key conflicts
- `-i <ssh_key_path>` — always uses the generated instance key

#### Scenario: ssh opens session to running instance
- **WHEN** a user runs `epi ssh dev-a` and `dev-a` is running with `ssh_port=54321`
- **THEN** the CLI execs `ssh -p 54321 -i <ssh_key_path> -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null <user>@127.0.0.1`
- **AND** epi's process is replaced by the ssh process (no wrapper)

#### Scenario: ssh fails if instance is not running
- **WHEN** `epi ssh dev-a` is invoked and `dev-a` has no active runtime
- **THEN** the command exits non-zero
- **AND** the error states that the instance is not running and suggests `epi start`

#### Scenario: ssh fails if no ssh_port is stored
- **WHEN** `epi ssh dev-a` is invoked and the runtime has no `ssh_port`
- **THEN** the command exits non-zero
- **AND** the error suggests stopping and restarting the instance

### Requirement: logs command streams journald output for the instance
The `epi logs` command SHALL display logs for the instance's systemd services by running `journalctl --user` for the instance's unit slice. If the instance has no known `unit_id`, the command fails with a clear error.

#### Scenario: logs streams journald output for running instance
- **WHEN** a user runs `epi logs dev-a` and `dev-a` has a stored `unit_id`
- **THEN** the CLI runs `journalctl --user -M "" --follow` (or equivalent) for the slice `epi-<escaped>_<unit_id>.slice`
- **AND** output from all services in the slice (VM, passt, virtiofsd) is shown

#### Scenario: logs fails if instance has no runtime
- **WHEN** `epi logs dev-a` is invoked and `dev-a` has no stored runtime
- **THEN** the command exits non-zero
- **AND** the error states that no runtime is found for the instance

