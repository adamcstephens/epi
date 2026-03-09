## Context

`epi launch` currently starts a VM process and returns immediately. The guest OS takes seconds to boot and start its SSH daemon, so scripted workflows like `epi launch && epi exec -- cmd` fail unless the user inserts manual sleeps. SSH infrastructure already exists: `ssh_port` is allocated during launch, `ssh_key_path` is optionally generated, and `epi ssh`/`epi exec` use these to connect. The missing piece is a polling loop that blocks until the guest SSH is ready.

The `--generate-ssh-key` flag is currently opt-in, but every user who wants `epi exec` or `epi ssh` needs it. Making key generation unconditional simplifies the CLI and guarantees the wait-for-SSH probe has a key to use.

## Goals / Non-Goals

**Goals:**
- `epi launch` and `epi start` block until SSH is reachable by default
- Unconditional SSH key generation removes a footgun
- Configurable timeout with env var override
- Progress feedback during the wait

**Non-Goals:**
- Health checks beyond SSH connectivity (e.g. cloud-init completion)
- TCP-only probe before SSH — a single `ssh ... true` attempt is sufficient and simpler
- Backwards compatibility for `--generate-ssh-key` flag (clean break)
- Backwards compatibility for `ssh_key_path` as optional in runtime state (existing runtimes without a key will be treated as stale and re-provisioned)

## Decisions

### 1. Probe method: `ssh ... true` only (no separate TCP check)

Run `ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i <key> -p <port> <user>@127.0.0.1 true` in a loop. If the TCP port isn't open yet, `ssh` fails with a connection error — no need for a separate TCP probe step. This keeps the implementation to a single `Process.run` call per attempt.

**Alternative**: TCP connect first, then SSH. Adds complexity for marginal time savings (TCP connect is ~instant when SSH is ready, and SSH already fails fast on connection refused).

### 2. Wait function lives in `vm_launch.ml`, called from `epi.ml`

`wait_for_ssh` is defined in `vm_launch.ml` alongside the other provisioning logic. `provision_and_report` in `epi.ml` calls it after `Vm_launch.provision` succeeds. This keeps provisioning concerns in `vm_launch.ml` and CLI flag resolution in `epi.ml`.

**Alternative**: Integrate wait into `Vm_launch.provision` itself. This would require threading `--no-wait` and `--wait-timeout` through the provision function, mixing CLI concerns into the provisioning module.

### 3. Return type: `(unit, provision_error) result`

`wait_for_ssh` returns a `provision_error` so the caller can use the same error reporting path as other provisioning failures. A new `Ssh_wait_timeout` variant is added to `provision_error`.

### 4. `ssh_key_path` becomes non-optional

`Instance_store.runtime.ssh_key_path` changes from `string option` to `string`. Deserialization of old runtimes missing this field returns `None` from `load_runtime`, which means those instances appear as "not provisioned" and get re-provisioned — acceptable since this is a breaking change.

### 5. Retry interval: 2 seconds

Poll every 2 seconds. Short enough for responsiveness, long enough to avoid spamming the guest during boot. Not configurable — only the total timeout is user-facing.

### 6. Progress output

Print `"vm: waiting for SSH (timeout %ds)..."` once at the start of the wait loop, then `"vm: SSH ready"` on success. No per-attempt output to avoid noise.

## Risks / Trade-offs

- **Old runtime files break** → Instances provisioned before this change lose their runtime state and must be re-provisioned. Acceptable for a dev tool.
- **ssh-keygen dependency** → Already required for `--generate-ssh-key`, now unconditional. Present on all target platforms.
- **120s default timeout may be too short for slow builds** → The timeout only covers the SSH wait after the VM process is running, not nix build time. 120s is generous for guest boot.
- **`--no-wait` still generates a key** → Key generation is ~instant and always useful. The flag only skips the polling loop.
