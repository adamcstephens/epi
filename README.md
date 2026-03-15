# epi - Ephemeral Instances

Create ephemeral virtual machines using nixosConfigurations.

## Quick start

```bash
# Launch a VM from a flake target
epi launch myvm --target '.#myConfig'

# SSH into it
epi ssh myvm

# Execute a command
epi exec myvm -- ls /

# Copy files
epi cp ./local-file myvm:/tmp/

# Stop and remove
epi stop myvm
epi rm myvm
```

## Configuration

epi merges configuration from three layers (highest priority first):

1. **CLI flags** — `--cpus`, `--memory`, `--mount`, `--port`, `--disk-size`
2. **Project config** — `.epi/config.toml` in the project directory
3. **User config** — `~/.config/epi/config.toml`

```toml
# .epi/config.toml
target = ".#myConfig"
default_name = "dev"
cpus = 4
memory = 2048
disk_size = "80G"
mounts = ["/home/user/data"]
ports = [":8080", "3000:3000"]
project_mount = true
```

All resolved values (cpus, memory, disk size, ports) are persisted in instance state at launch time. Subsequent `start` and `rebuild` commands use the stored values.

### Project initialization

```bash
epi init
```

Interactively creates a `.epi/config.toml` with target selection and default settings.

## Commands

| Command | Description |
|---|---|
| `launch` | Create and start an instance from a flake target |
| `start` | Start an existing stopped instance |
| `stop` | Stop an instance |
| `rm` | Remove an instance |
| `rebuild` | Rebuild an instance (re-evaluates target, fresh disk) |
| `info` | Show detailed instance information |
| `list` | List known instances |
| `ssh` | Open SSH session |
| `exec` | Execute a command in an instance |
| `cp` | Copy files between host and instance via rsync |
| `console` | Attach to serial console |
| `console-log` | Show captured console output |
| `logs` | Show instance logs |
| `ssh-config` | Output SSH config block for an instance |
| `init` | Initialize a new epi project |
| `completions` | Generate shell completions (fish, bash, zsh) |

## Port mapping

Map TCP ports from host to guest with `--port`:

```bash
# Auto-assign host port, forward to guest port 8080
epi launch myvm --port :8080

# Explicit host:guest mapping
epi launch myvm --port 3000:3000 --port 8443:443
```

Ports can also be set in config via `ports = [":8080", "3000:3000"]`.

## Shell completions

```bash
epi completions fish | source                          # fish
source <(epi completions bash)                         # bash
source <(epi completions zsh)                          # zsh
```

Completions include dynamic instance name tab-completion.

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
