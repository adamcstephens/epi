## Why

Users need a way to run commands inside VMs without opening an interactive SSH session. This enables scripting, automation, and quick one-off commands against running instances.

## What Changes

- Add `epi exec` subcommand that runs a command inside a running VM instance via SSH and returns its output/exit code
- The command uses the same SSH connection infrastructure as `epi ssh` but passes through a command instead of opening an interactive session

## Capabilities

### New Capabilities
- `exec-command`: Execute a command inside a running VM instance via SSH, returning stdout/stderr and the remote exit code

### Modified Capabilities
- `dev-instance-cli`: Add `exec` to the set of lifecycle commands that operate on instance identity

## Impact

- `lib/epi.ml`: New `exec_command` definition and registration in the command group
- CLI surface: New `exec` subcommand visible in `epi --help`
- No new dependencies — reuses existing SSH connection details from instance runtime state
