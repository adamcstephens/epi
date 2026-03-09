## Purpose
Define the CLI surface for managing development VM instances, including creation, lifecycle operations, and instance inventory.
## Requirements
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
The CLI SHALL provide a `list` command that outputs known instance names and their associated targets.

#### Scenario: Multiple instances exist
- **WHEN** a user runs `epi list` with `default`, `dev-a`, and `qa-1` defined
- **THEN** the output includes each instance name
- **AND** the output includes the stored target for each instance

### Requirement: Launch reports SSH connection details after successful launch
After a successful `epi launch`, the CLI SHALL print the host port forwarded to the VM's SSH port so the user can connect immediately.

#### Scenario: SSH port is printed on successful launch
- **WHEN** `epi launch dev-a --target .#dev-a` succeeds
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

### Requirement: ssh command opens an SSH session to a running instance
The `epi ssh` command SHALL resolve the instance's stored SSH port and exec into `ssh`, replacing the epi process. It SHALL not wrap or proxy the SSH connection — the user's terminal is handed directly to `ssh`.

Connection parameters:
- Host: `127.0.0.1`
- Port: the stored `ssh_port` from the instance runtime
- User: `$USER` from the environment (falls back to `user` if unset)
- `StrictHostKeyChecking=no` — VMs generate fresh host keys on each provision
- `UserKnownHostsFile=/dev/null` — prevents stale host key conflicts
- If `ssh_key_path` is stored in the runtime (from `--generate-ssh-key`), `-i <path>` is added

#### Scenario: ssh opens session to running instance
- **WHEN** a user runs `epi ssh dev-a` and `dev-a` is running with `ssh_port=54321`
- **THEN** the CLI execs `ssh -p 54321 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null <user>@127.0.0.1`
- **AND** epi's process is replaced by the ssh process (no wrapper)

#### Scenario: ssh with generated key passes -i flag
- **WHEN** `dev-a` was launched with `--generate-ssh-key` and has `ssh_key_path` stored
- **THEN** the CLI adds `-i <ssh_key_path>` before the host argument

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

