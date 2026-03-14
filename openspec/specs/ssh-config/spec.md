### Requirement: SSH config file generation
After a VM is launched and SSH connectivity is confirmed, the system SHALL write an SSH config file to `<state_dir>/<instance_name>/ssh_config` containing the minimal options needed to connect.

#### Scenario: Config file written after successful launch
- **WHEN** a VM is launched and `wait_for_ssh` succeeds
- **THEN** the file `<state_dir>/<instance_name>/ssh_config` SHALL exist with a `Host` block using the instance name as alias

#### Scenario: Config file contains required options
- **WHEN** the SSH config file is generated for an instance with name `myvm`, port `12345`, user `adam`, and key path `/home/adam/.epi/state/myvm/id_ed25519`
- **THEN** the file SHALL contain:
  - `Host myvm`
  - `HostName 127.0.0.1`
  - `Port 12345`
  - `User adam`
  - `IdentityFile /home/adam/.epi/state/myvm/id_ed25519`
  - `IdentitiesOnly yes`
  - `StrictHostKeyChecking no`
  - `UserKnownHostsFile /dev/null`
  - `LogLevel ERROR`

#### Scenario: Host alias matches instance name
- **WHEN** the instance is named `dev-server`
- **THEN** the config file SHALL use `Host dev-server` as the alias

### Requirement: Internal SSH commands use config file
All internal SSH invocations (`ssh`, `exec`, `cp`) SHALL use `ssh -F <config_path> <instance_name>` instead of constructing connection options inline.

#### Scenario: SSH command uses config file
- **WHEN** a user runs `epi ssh <name>`
- **THEN** the SSH process SHALL be invoked with `-F <state_dir>/<name>/ssh_config` and the instance name as the host argument

#### Scenario: Exec command uses config file
- **WHEN** a user runs `epi exec <name> -- <command>`
- **THEN** the SSH process SHALL be invoked with `-F <state_dir>/<name>/ssh_config` and the instance name as the host argument, followed by `--` and the command

#### Scenario: Copy command uses config file
- **WHEN** a user runs `epi cp` with a remote path
- **THEN** the rsync `-e` flag SHALL use `ssh -F <config_path>` and remote paths SHALL use the instance name as host

### Requirement: SSH config CLI subcommand
The system SHALL provide an `epi ssh-config <name>` subcommand to retrieve the SSH config for a running instance.

#### Scenario: Print config path
- **WHEN** a user runs `epi ssh-config <name>`
- **THEN** the system SHALL print the absolute path to the SSH config file to stdout

#### Scenario: Print config contents
- **WHEN** a user runs `epi ssh-config <name> --print`
- **THEN** the system SHALL print the contents of the SSH config file to stdout

#### Scenario: Instance not running
- **WHEN** a user runs `epi ssh-config <name>` and the instance is not running
- **THEN** the system SHALL exit with an error indicating the instance is not running

### Requirement: wait_for_ssh uses additional options
The `wait_for_ssh` function SHALL continue to pass `BatchMode=yes` and `ConnectTimeout=5` as additional options alongside the config file.

#### Scenario: SSH readiness check with config
- **WHEN** `wait_for_ssh` polls for SSH connectivity
- **THEN** it SHALL invoke SSH with `-F <config_path>`, `-o BatchMode=yes`, `-o ConnectTimeout=5`, and the instance name as host
