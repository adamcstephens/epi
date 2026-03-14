## Context

SSH connection options are currently constructed inline across `cmd_ssh`, `cmd_exec`, `cmd_cp`, and `wait_for_ssh`. Each duplicates the same set of options: `StrictHostKeyChecking=no`, `UserKnownHostsFile=/dev/null`, `LogLevel=ERROR`, identity file, and port. Users who want to connect with plain `ssh` must dig into `state.json` to find the port and key path.

## Goals / Non-Goals

**Goals:**
- Write a per-instance `ssh_config` file to the instance state directory after SSH is ready
- Use the instance name as the `Host` alias so `ssh <name>` works
- Add a `ssh-config` CLI subcommand to print the config path or contents
- Refactor internal SSH invocations to use `ssh -F <config>`

**Non-Goals:**
- Global SSH config management (no `~/.ssh/config` modifications)
- SSH agent forwarding or multiplexing configuration
- Config file updates when instance state changes (config is written once at launch)

## Decisions

**Config file location**: `<state_dir>/<instance_name>/ssh_config`
- Consistent with other instance artifacts (key, state.json, disk)
- No risk of conflicting with user's `~/.ssh/config`

**Config contents**: Minimal set of options needed to connect:
```
Host <instance_name>
    HostName 127.0.0.1
    Port <ssh_port>
    User <username>
    IdentityFile <ssh_key_path>
    IdentitiesOnly yes
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
```

**Internal refactor**: Replace inline arg construction with `ssh -F <config_path>` plus the host alias. This eliminates the duplicated option lists in `cmd_ssh`, `cmd_exec`, and `cmd_cp`. `wait_for_ssh` additionally needs `BatchMode=yes` and `ConnectTimeout=5`, which can be passed as extra `-o` flags alongside `-F`.

**CLI subcommand**: `epi ssh-config <name>` prints the config file path by default. With `--print` it prints the file contents (useful for piping into `cat >> ~/.ssh/config` or `Include`).

## Risks / Trade-offs

**Stale config on port change** → Port is allocated once per launch and doesn't change during VM lifetime. Config is only valid while the VM is running, same as `state.json`. No mitigation needed.

**Absolute path in IdentityFile** → Required because `ssh -F` doesn't resolve relative paths against the config file location. Paths are already absolute in `Runtime::ssh_key_path`.
