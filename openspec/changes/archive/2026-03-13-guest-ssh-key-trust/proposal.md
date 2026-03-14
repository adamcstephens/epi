## Why

The SSH config currently disables host key checking (`StrictHostKeyChecking no`, `UserKnownHostsFile /dev/null`). This means a MITM on localhost could intercept VM connections without detection. Since we control the guest, we can record its host key after first boot and pin it in a per-instance known_hosts file, enabling strict host key checking for all subsequent connections.

## What Changes

- Generate an initial SSH config before `wait_for_ssh` with host key checking disabled (as today)
- After SSH becomes reachable, run `ssh-keyscan` to capture the guest's host key and store it in `<state_dir>/<instance_name>/known_hosts`
- Rewrite the SSH config to enable `StrictHostKeyChecking yes` and point `UserKnownHostsFile` at the per-instance known_hosts file
- All subsequent SSH commands (`ssh`, `exec`, `cp`) use the trusted config automatically

## Capabilities

### New Capabilities

### Modified Capabilities
- `ssh-config`: Config generation becomes a two-pass process — initial untrusted config for boot polling, then trusted config with pinned host key after SSH is reachable

## Impact

- `src/ssh.rs`: `generate_config` gains a `known_hosts` parameter, new `record_host_key` function, config rewrite after `wait_for_ssh`
- `src/main.rs`: launch/start/rebuild flows call host key recording between `wait_for_ssh` and post-launch hooks
- Instance state directory gains a `known_hosts` file per instance
