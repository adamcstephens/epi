## MODIFIED Requirements

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

## REMOVED Requirements

### Requirement: ssh with generated key passes -i flag
**Reason**: `-i <ssh_key_path>` is now always passed since key generation is unconditional. The conditional behavior described in the original scenario is removed.
**Migration**: No action needed. `ssh` always uses the generated key.
