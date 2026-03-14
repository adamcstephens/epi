## ADDED Requirements

### Requirement: Guest host key recording
After `wait_for_ssh` succeeds, the system SHALL run `ssh-keyscan` to capture the guest's SSH host key and store it at `<state_dir>/<instance_name>/known_hosts`.

#### Scenario: Host key recorded after SSH is reachable
- **WHEN** `wait_for_ssh` succeeds for an instance on port `12345`
- **THEN** the system SHALL run `ssh-keyscan -p 12345 127.0.0.1` and write the output to `<state_dir>/<instance_name>/known_hosts`

#### Scenario: Keyscan failure is non-fatal
- **WHEN** `ssh-keyscan` fails (e.g. SSH becomes unreachable between wait and scan)
- **THEN** the system SHALL log a warning and leave the untrusted config in place, without failing the launch

### Requirement: Trusted config rewrite
After the host key is recorded, the system SHALL rewrite the SSH config to enable strict host key checking.

#### Scenario: Config updated with known_hosts
- **WHEN** the host key has been successfully recorded to `known_hosts`
- **THEN** the SSH config SHALL be rewritten with `StrictHostKeyChecking yes` and `UserKnownHostsFile <state_dir>/<instance_name>/known_hosts`

#### Scenario: Config retains untrusted settings on keyscan failure
- **WHEN** `ssh-keyscan` fails
- **THEN** the SSH config SHALL remain unchanged with `StrictHostKeyChecking no` and `UserKnownHostsFile /dev/null`

## MODIFIED Requirements

### Requirement: SSH config file generation
After a VM is launched and SSH connectivity is confirmed, the system SHALL write an SSH config file to `<state_dir>/<instance_name>/ssh_config` containing the minimal options needed to connect.

#### Scenario: Config file written after successful launch
- **WHEN** a VM is launched and `wait_for_ssh` succeeds
- **THEN** the file `<state_dir>/<instance_name>/ssh_config` SHALL exist with a `Host` block using the instance name as alias

#### Scenario: Initial config before SSH is reachable
- **WHEN** the SSH config is first generated (before `wait_for_ssh`)
- **THEN** the file SHALL contain `StrictHostKeyChecking no` and `UserKnownHostsFile /dev/null`

#### Scenario: Trusted config after host key recording
- **WHEN** the host key has been successfully recorded
- **THEN** the file SHALL contain `StrictHostKeyChecking yes` and `UserKnownHostsFile <state_dir>/<instance_name>/known_hosts`

#### Scenario: Config file contains required options
- **WHEN** the SSH config file is generated for an instance with name `myvm`, port `12345`, user `adam`, and key path `/home/adam/.epi/state/myvm/id_ed25519`
- **THEN** the file SHALL contain:
  - `Host myvm`
  - `HostName 127.0.0.1`
  - `Port 12345`
  - `User adam`
  - `IdentityFile /home/adam/.epi/state/myvm/id_ed25519`
  - `IdentitiesOnly yes`
  - `LogLevel ERROR`

#### Scenario: Host alias matches instance name
- **WHEN** the instance is named `dev-server`
- **THEN** the config file SHALL use `Host dev-server` as the alias
