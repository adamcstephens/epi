# exec-command Specification

## Purpose
TBD - created by archiving change add-exec-subcommand. Update Purpose after archive.
## Requirements
### Requirement: Exec runs a command inside a running instance via SSH
The CLI SHALL provide an `exec` command that accepts an optional positional instance name followed by `--` and a command with arguments. The command SHALL be executed inside the VM via SSH, and the CLI SHALL forward stdout and stderr from the remote process.

#### Scenario: Run a command on the default instance
- **WHEN** a user runs `epi exec -- ls /tmp`
- **THEN** the CLI connects to instance `default` via SSH
- **AND** executes `ls /tmp` inside the VM
- **AND** prints the remote stdout to local stdout

#### Scenario: Run a command on a named instance
- **WHEN** a user runs `epi exec dev-a -- uname -a`
- **THEN** the CLI connects to instance `dev-a` via SSH
- **AND** executes `uname -a` inside the VM

### Requirement: Exec exits with the remote command's exit code
The CLI SHALL exit with the same exit code as the remote command. This enables callers to detect success or failure of the remote execution.

#### Scenario: Remote command succeeds
- **WHEN** a user runs `epi exec -- true`
- **THEN** the CLI exits with code 0

#### Scenario: Remote command fails
- **WHEN** a user runs `epi exec -- false`
- **THEN** the CLI exits with a non-zero exit code

### Requirement: Exec fails clearly when instance is not running
If the target instance is not running, the CLI SHALL exit non-zero with a message indicating the instance is not running.

#### Scenario: Instance not running
- **WHEN** a user runs `epi exec -- ls` and instance `default` is not running
- **THEN** the CLI exits non-zero
- **AND** the error message indicates the instance is not running

### Requirement: Exec fails clearly when no SSH port is available
If the target instance has no SSH port configured, the CLI SHALL exit non-zero with an actionable message.

#### Scenario: No SSH port
- **WHEN** a user runs `epi exec dev-a -- ls` and instance `dev-a` has no SSH port
- **THEN** the CLI exits non-zero
- **AND** the error message indicates no SSH port is available

### Requirement: Exec requires a command after --
The CLI SHALL require at least one argument after `--`. If no command is provided, the CLI SHALL exit non-zero with usage guidance.

#### Scenario: No command provided
- **WHEN** a user runs `epi exec`
- **THEN** the CLI exits non-zero
- **AND** the error indicates a command is required

