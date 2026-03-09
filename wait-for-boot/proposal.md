## Why

After `epi launch` returns, the VM process is running but the guest OS has not finished booting. Users who want to script sequences like `epi launch --target .#foo && epi exec -- some-command` must insert arbitrary sleeps or manual retry loops because there is no way to know when SSH inside the guest is ready to accept connections. This makes automation fragile and wastes time on both under-sleeping (command fails) and over-sleeping (unnecessary delay).

## What Changes

- Wait for SSH connectivity by default after successful VM provisioning in `epi launch` and `epi start`. Add `--no-wait` flag to opt out and return immediately after the VM process starts (previous behavior).
- After the VM process is verified running, poll SSH connectivity by attempting a TCP connection to the forwarded SSH port followed by an `ssh` connection that runs a trivial command (e.g. `true`)
- Use a retry loop with a configurable timeout (default 120 seconds via `--wait-timeout`, overridable with `EPI_WAIT_TIMEOUT_SECONDS` env var) and a short interval between attempts
- Print progress messages during the wait so the user can distinguish active waiting from a hung command
- Exit non-zero with a clear error if the timeout is reached without establishing SSH connectivity
- Make SSH key generation unconditional -- every `epi launch` generates an ed25519 keypair for the instance. Remove the `--generate-ssh-key` flag.
- Use only the generated key for SSH connections: `epi ssh` and `epi exec` always pass `-i <generated_key_path>` and no longer fall back to the user's `~/.ssh` keys. User public keys from `~/.ssh/*.pub` are still added to `ssh_authorized_keys` in cloud-init so manual `ssh -p <port>` still works.

## Capabilities

### Modified Capabilities
- `vm-provision-from-target`: Always generate an SSH keypair during provisioning. After successful VM launch, poll SSH until the guest is reachable before returning success (unless `--no-wait` is passed).
- `dev-instance-cli`: Replace `--generate-ssh-key` with unconditional key generation. Add `--no-wait` and `--wait-timeout` flags to `launch` and `start`. `ssh` and `exec` commands always use the generated key.

## Impact

- `lib/vm_launch.ml`: SSH key generation becomes unconditional in `launch_detached`. New `wait_for_ssh` function that polls SSH connectivity using the runtime's `ssh_port` and generated `ssh_key_path`. `ssh_key_path` in the runtime is no longer optional.
- `lib/epi.ml`: Remove `--generate-ssh-key` flag from `launch_command`. Add `--no-wait` and `--wait-timeout` flags to `launch_command` and `start_command`. `ssh_command` and `exec_command` always use `ssh_key_path` (no longer conditional). Wait logic called in `provision_and_report` by default.
- `lib/instance_store.ml`: `ssh_key_path` field in `runtime` changes from `string option` to `string`
- No new dependencies -- reuses the system `ssh` binary already used by `epi ssh` and `epi exec`
