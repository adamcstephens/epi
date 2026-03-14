## Context

The SSH config (`ssh_config`) is generated immediately after provisioning with `StrictHostKeyChecking no` and `UserKnownHostsFile /dev/null`. This allows `wait_for_ssh` to connect without knowing the guest's host key. Once SSH is reachable, the guest's host key is stable for the lifetime of the instance and can be pinned.

## Goals / Non-Goals

**Goals:**
- Record the guest's SSH host key after first successful connection
- Rewrite the SSH config to enforce strict host key checking using the recorded key
- Make this transparent — no user action required

**Non-Goals:**
- Rotating host keys during instance lifetime
- Supporting multiple host key types (one is sufficient for trust)
- Modifying the guest's SSH server configuration

## Decisions

**Two-pass config generation**: `generate_config` accepts an optional `known_hosts_path`. When `None`, it writes `StrictHostKeyChecking no` and `UserKnownHostsFile /dev/null` (the initial boot config). When `Some(path)`, it writes `StrictHostKeyChecking yes` and `UserKnownHostsFile <path>` (the trusted config). This keeps a single generation function rather than two separate ones.

Alternative: patch the file in place with sed-style replacement. Rejected because regenerating the whole file is simpler and the function already exists.

**Host key capture via `ssh-keyscan`**: Run `ssh-keyscan -p <port> 127.0.0.1` after `wait_for_ssh` succeeds. This is a standard tool, already available on any system with OpenSSH. The output is written directly to `<state_dir>/<instance_name>/known_hosts`.

Alternative: extract the key from the guest filesystem via virtiofs or serial. Rejected — `ssh-keyscan` is simpler and doesn't require filesystem access.

**Flow**: provision → generate untrusted config → `wait_for_ssh` → `ssh-keyscan` → generate trusted config → post-launch hooks. The trusted config is what all subsequent commands use.

## Risks / Trade-offs

**`ssh-keyscan` failure** → If keyscan fails (e.g. SSH goes down between `wait_for_ssh` and keyscan), fall back to keeping the untrusted config. Log a warning but don't fail the launch.

**Host key changes on rebuild** → Rebuild already regenerates the config. The new keyscan will capture the new key. No special handling needed.
