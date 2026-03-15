## Purpose
Define the CLI surface for managing development VM instances, including creation, lifecycle operations, and instance inventory.
## Requirements
### Requirement: Launch command creates or starts an instance from a target
The CLI SHALL provide a `launch` command that accepts an optional positional instance name and an optional `--target <flake#config>` option. If the instance name is omitted, the CLI MUST use the `default_name` from config, falling back to `default` if not configured. If `--target` is omitted, the CLI SHALL look for a `target` value in the project config file (`.epi/config.toml`). If neither CLI nor config provides a target, the CLI MUST exit non-zero with an error message explaining both ways to provide a target. The command SHALL accept `--no-provision` to skip post-launch provisioning (SSH wait, host key trust, hooks), `--wait-timeout` to configure the SSH wait duration, `--cpus` to override the descriptor CPU count, and `--memory` to override the descriptor memory size.

During launch, the CLI SHALL show step-based progress output on stderr: a spinner during provisioning with elapsed time, and a spinner during SSH wait with elapsed time. On completion, the CLI SHALL display a success message with the SSH port. When `--console` is active, the CLI SHALL skip spinners (to avoid corrupting raw terminal mode) and use plain text messages instead.

#### Scenario: Explicit instance name provided
- **WHEN** a user runs `epi launch dev-a --target .#dev-a`
- **THEN** the CLI resolves instance name `dev-a`
- **AND** the CLI resolves target `.#dev-a`

#### Scenario: Instance name omitted uses default_name from config
- **WHEN** `.epi/config.toml` contains `default_name = "dev"`
- **AND** a user runs `epi launch --target .#dev`
- **THEN** the CLI resolves instance name `dev`

#### Scenario: Instance name omitted with no default_name configured
- **WHEN** no config sets `default_name`
- **AND** a user runs `epi launch --target github:org/repo#dev`
- **THEN** the CLI resolves instance name `default`

#### Scenario: --cpus flag overrides descriptor
- **WHEN** a user runs `epi launch --cpus 4`
- **THEN** the VM is launched with 4 CPUs regardless of the descriptor value

#### Scenario: --memory flag overrides descriptor
- **WHEN** a user runs `epi launch --memory 4096`
- **THEN** the VM is launched with 4096 MiB of memory regardless of the descriptor value

#### Scenario: --no-provision flag skips post-launch provisioning
- **WHEN** a user runs `epi launch dev-a --target .#dev-a --no-provision`
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
- **AND** on success, a "checkmark" prefixed message shows the instance is ready with the SSH port

#### Scenario: Plain progress with --console flag
- **WHEN** a user runs `epi launch --console`
- **THEN** the SSH wait in the background thread uses plain `eprintln!` messages instead of spinners

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
The CLI SHALL treat lifecycle commands as operating on instance identity, not on target identity. The commands `stop`, `rebuild`, `ssh`, `exec`, and `logs` SHALL accept an optional positional instance name and MUST use the `default_name` from config when omitted, falling back to `default` if not configured.

#### Scenario: Explicit lifecycle target
- **WHEN** a user runs `epi stop dev-a`
- **THEN** the CLI selects instance `dev-a` for shutdown

#### Scenario: Implicit default lifecycle target with default_name configured
- **WHEN** `.epi/config.toml` contains `default_name = "dev"`
- **AND** a user runs `epi ssh`
- **THEN** the CLI selects instance `dev`

#### Scenario: Implicit default lifecycle target without default_name
- **WHEN** no config sets `default_name`
- **AND** a user runs `epi ssh`
- **THEN** the CLI selects instance `default`

#### Scenario: Exec uses configured default instance
- **WHEN** `.epi/config.toml` contains `default_name = "dev"`
- **AND** a user runs `epi exec -- hostname`
- **THEN** the CLI selects instance `dev`

### Requirement: Missing default instance returns clear guidance
If a lifecycle command is invoked without an instance name and `default` does not exist, the CLI MUST fail with a clear message explaining how to create `default` or specify another instance.

#### Scenario: Default missing on lifecycle command
- **WHEN** a user runs `epi info` and no `default` instance exists
- **THEN** the CLI exits non-zero
- **AND** the error message mentions `default` was not found
- **AND** the error message suggests running `epi launch --target <flake#config>` or passing an instance name

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

### Requirement: Launch reports SSH connection details after successful launch
After a successful `epi launch`, the CLI SHALL print the host port forwarded to the VM's SSH port as part of the success step message so the user can connect immediately.

#### Scenario: SSH port is printed on successful launch
- **WHEN** `epi launch dev-a --target .#dev-a` succeeds
- **THEN** the CLI prints a "checkmark" prefixed message indicating the instance is ready with the SSH port number

### Requirement: Status includes forwarded SSH port
The `epi info` command SHALL display instance details in a labeled field format. The output SHALL include the instance name (bold), target, and running status with a colored dot indicator. When the instance is running with runtime metadata, the output SHALL additionally include SSH port, serial socket path, disk path, and unit ID.

#### Scenario: Status shows full runtime details for running instance
- **WHEN** a user runs `epi info dev-a` and `dev-a` is running with SSH port 54321
- **THEN** the output shows `instance:  dev-a` with the name in bold
- **AND** the output shows `target:    .#dev-a`
- **AND** the output shows `status:    ● running` with the dot in green
- **AND** the output shows `ssh port:  54321`
- **AND** the output shows `serial:`, `disk:`, and `unit id:` fields

#### Scenario: Status shows runtime fields even when stopped
- **WHEN** a user runs `epi info dev-a` and `dev-a` is stopped but has stored runtime metadata
- **THEN** the output shows `instance:  dev-a` with the name in bold
- **AND** the output shows `target:    .#dev-a`
- **AND** the output shows `status:    ○ stopped` with the dot dimmed
- **AND** runtime fields (ssh port, serial, disk, unit id) are still shown if runtime metadata exists

### Requirement: ssh command opens an SSH session to a running instance
The `epi ssh` command SHALL resolve the instance's stored SSH port and exec into `ssh`, replacing the epi process. It SHALL not wrap or proxy the SSH connection — the user's terminal is handed directly to `ssh`.

Connection parameters:
- Host: `127.0.0.1`
- Port: the stored `ssh_port` from the instance runtime
- User: `$USER` from the environment (falls back to `user` if unset)
- `StrictHostKeyChecking=no` — VMs generate fresh host keys on each provision
- `UserKnownHostsFile=/dev/null` — prevents stale host key conflicts
- `LogLevel=ERROR` — suppresses SSH warnings about unknown host keys
- `-i <ssh_key_path>` — always uses the generated instance key

#### Scenario: ssh opens session to running instance
- **WHEN** a user runs `epi ssh dev-a` and `dev-a` is running with `ssh_port=54321`
- **THEN** the CLI execs `ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i <ssh_key_path> -p 54321 <user>@127.0.0.1`
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
