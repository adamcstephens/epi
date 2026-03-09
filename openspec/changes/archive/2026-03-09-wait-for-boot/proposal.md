## Why

After `epi launch` returns, the VM process is running but the guest OS has not finished booting. Users who script `epi launch && epi exec -- some-command` must insert arbitrary sleeps because there is no signal for when SSH is ready. This makes automation fragile and wastes time.

## What Changes

- Wait for SSH connectivity by default after successful VM provisioning in `epi launch` and `epi start`. Add `--no-wait` flag to opt out and return immediately (previous behavior).
- After the VM process is verified running, poll SSH by attempting `ssh ... true` in a retry loop until the guest responds.
- Use a configurable timeout (default 120 seconds via `--wait-timeout`, overridable with `EPI_WAIT_TIMEOUT_SECONDS` env var) with a short interval between attempts.
- Print progress messages during the wait so the user can distinguish active waiting from a hung command.
- Exit non-zero with a clear error if the timeout is reached without SSH connectivity.
- **BREAKING**: Make SSH key generation unconditional — every `epi launch` generates an ed25519 keypair. Remove `--generate-ssh-key` flag.
- **BREAKING**: `epi ssh` and `epi exec` always use the generated key (`-i <path>`). User `~/.ssh/*.pub` keys are still added to cloud-init `ssh_authorized_keys` so manual `ssh -p <port>` works.
- `ssh_key_path` in runtime state changes from `string option` to `string` (always present).
- `epi start` also generates a key and waits for SSH (reuses the same wait logic).

## Capabilities

### New Capabilities

### Modified Capabilities
- `vm-provision-from-target`: Always generate an SSH keypair during provisioning. After successful VM launch, poll SSH until the guest is reachable before returning success (unless `--no-wait`). Add `Ssh_wait_timeout` error variant.
- `dev-instance-cli`: Remove `--generate-ssh-key` flag (unconditional). Add `--no-wait` and `--wait-timeout` flags to `launch` and `start`. `ssh` and `exec` always use generated key (no conditional `-i`).
- `vm-start-command`: Start generates a key and waits for SSH by default. Add `--no-wait` and `--wait-timeout` flags.

## Impact

- `lib/vm_launch.ml`: SSH key generation becomes unconditional in `launch_detached` (remove `~generate_ssh_key` parameter). New `wait_for_ssh` function polls SSH connectivity. New `Ssh_wait_timeout` error variant. `ssh_key_path` in returned runtime is `string` not `string option`.
- `lib/vm_launch.mli`: Update `provision` signature (remove `~generate_ssh_key`), add `wait_for_ssh`, update error type.
- `lib/epi.ml`: Remove `--generate-ssh-key` flag. Add `--no-wait` / `--wait-timeout` flags to `launch_command` and `start_command`. Call `wait_for_ssh` in `provision_and_report`. Simplify `ssh_command`/`exec_command` key handling (always present). `start_command` always generates key.
- `lib/instance_store.ml`: `ssh_key_path` changes from `string option` to `string` in `runtime` type. Update serialization/deserialization.
- `lib/instance_store.mli`: Update `runtime` type.
- `test/`: Update tests for removed flag, new flags, non-optional key path.
