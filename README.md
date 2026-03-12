# epi - Ephemeral Instances

Create ephemeral virtual machines using nixosConfigurations

## Hooks

epi supports hook scripts at three points in the instance lifecycle. Hooks are discovered from three layers, executed in this order:

1. **User hooks** — `~/.config/epi/hooks/<hook>.d/`
2. **Project hooks** — `.epi/hooks/<hook>.d/`
3. **Nix hooks** — declared in the nixosConfiguration via `epi.hooks.<hook>`

Within each layer, scripts are sorted by filename. Only executable files are run; non-executable files produce a warning. Each layer also supports instance-specific subdirectories (`<hook>.d/<instance-name>/`) whose scripts run after the layer's top-level scripts.

### post-launch

Runs on the **host** after the VM is reachable via SSH. Useful for provisioning the guest from the outside (e.g. copying dotfiles, running commands over SSH).

Scripts receive the following environment variables:

| Variable | Description |
|---|---|
| `EPI_INSTANCE` | Instance name |
| `EPI_SSH_PORT` | SSH port on localhost |
| `EPI_SSH_KEY` | Path to the SSH private key |
| `EPI_SSH_USER` | SSH username |
| `EPI_STATE_DIR` | Instance state directory |
| `EPI_BIN` | Path to the running epi binary |

If any hook exits non-zero, execution stops and the error is reported.

Since hooks run on the host (not inside the VM), use `$EPI_BIN exec` to run commands in the guest:

```bash
jq '{oauthAccount,userID,theme,firstStartTime,installMethod,hasCompletedOnboarding}' ~/.claude.json \
  | "$EPI_BIN" exec "$EPI_INSTANCE" -- "cat > .claude.json"
```

### guest-init

Runs **inside the guest VM** on first boot only, as the provisioned user, after user creation, hostname, SSH keys, and mounts are configured. Network connectivity is available. Useful for installing packages or configuring the guest environment.

File-based hooks (from user and project layers) are embedded in the seed ISO at launch time. Nix-declared hooks are baked into the VM image. Seed ISO hooks run first, then Nix hooks. If a hook fails, the failure is logged and remaining hooks continue. SSH is available before hooks finish — they do not block the boot.

### pre-stop

Runs on the **host** before the VM is stopped. Useful for cleanup tasks like syncing data or saving state.

Receives the same environment variables as post-launch hooks. If any hook exits non-zero, execution stops and the error is reported (but the VM is still stopped).
