## Why

Currently, SSH connection details (host, port, key, user, options) are constructed inline in every command that needs SSH access (`ssh`, `exec`, `cp`, `wait_for_ssh`, hooks). There's no way for users to connect to a VM using standard SSH tooling without manually looking up the port and key path from `state.json`. Writing an SSH config file per instance would let users run `ssh <name>` directly and simplify internal SSH command construction.

## What Changes

- After a VM is launched and SSH is ready, write an SSH config file to the instance state directory
- The config uses the instance name as the `Host` alias with all connection options underneath
- Add a new `ssh-config` CLI command that prints the path to (or contents of) the SSH config for a given instance, so users can `Include` it or use `ssh -F`
- Refactor internal SSH command construction to read options from the config file instead of building args inline

## Capabilities

### New Capabilities
- `ssh-config`: Generation of per-instance SSH config files with Host alias matching the instance name, and a CLI command to retrieve them

### Modified Capabilities

## Impact

- `src/main.rs`: `cmd_ssh`, `cmd_exec`, `cmd_cp` — simplify SSH arg construction
- `src/vm_launch.rs`: write SSH config after `wait_for_ssh` succeeds
- Instance state directory gains a new `ssh_config` file per instance
