## Context

epi already has an `ssh` subcommand that opens an interactive SSH session to a running VM instance. It resolves the instance, checks for a running process and SSH port, then `execvp`s into `ssh`. The `exec` subcommand follows the same pattern but passes a command through to SSH instead of opening an interactive session.

## Goals / Non-Goals

**Goals:**
- Allow users to run a single command inside a VM and get its output and exit code
- Reuse existing SSH connection infrastructure (port, key, host-key options)
- Follow the same instance resolution pattern as other lifecycle commands

**Non-Goals:**
- Interactive/PTY allocation — `exec` is for non-interactive command execution
- Stdin forwarding to the remote command
- Multiplexed or persistent SSH connections

## Decisions

### Use `Unix.execvp` to replace the process with SSH
Same approach as `ssh_command`. The epi process replaces itself with the `ssh` process, which naturally propagates the remote exit code back to the caller. No need to capture output or manage child processes.

**Alternative**: Spawn SSH as a child process and wait for it. Rejected because `execvp` is simpler and the existing `ssh` command already establishes this pattern.

### Accept command after `--` separator using cmdlang trailing positional args
The command and its arguments are collected as trailing positional arguments. The `--` separator is standard CLI convention and handled by cmdliner automatically.

### Disable PTY allocation with `-T`
Since `exec` is for non-interactive use, pass `-T` to SSH to disable pseudo-terminal allocation. This ensures clean stdout/stderr without terminal escape sequences.

## Risks / Trade-offs

- [SSH not available] → Same risk as `ssh` command; user gets a clear error if no SSH port is configured.
- [No stdin forwarding] → Keeps scope minimal. Users needing stdin can use `epi ssh` with pipes.
