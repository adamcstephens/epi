# epi - Ephemeral Instances

Create ephemeral virtual machines using nixosConfigurations.

## Requirements

- nix
- systemd user environment

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

1. **CLI flags** — `--cpus`, `--memory`, `--mount <src>[:<dst>][:ro]`, `--port`, `--disk-size`
2. **Project config** — `.epi/config.toml` in the current directory
3. **User config** — `~/.config/epi/config.toml`

For scalar values (target, cpus, memory, disk_size, default_name, project_dir), the highest-priority layer wins. For list values (mounts, ports), all layers are merged (union, deduplicated).

```toml
# .epi/config.toml
target = ".#myConfig"
default_name = "dev"
project_dir = "/home/user/src/my-project"
cpus = 4
memory = 2048
disk_size = "80G"
mounts = ["/home/user/data:ro"]
ports = [":8080", "3000:3000"]
project_mount = true
```

`project_dir` identifies the host project independently of the configuration file. The project value overrides the user value. Relative values are resolved against the directory containing the file that declares them, `~` expands from `HOME`, and the resulting path must exist and be a directory. EPI persists the canonical resolved directory in instance state; subsequent `start` and `rebuild` commands use that state rather than re-reading configuration.

### Hjem

EPI provides a Hjem module for declaring user-systemd services. Import it through Hjem's `extraModules`, then configure instances for the matching Hjem user:

```nix
{
  hjem.extraModules = [ inputs.epi.hjemModules.default ];

  hjem.users.alice.services.epi = {
    package = inputs.epi.packages.${pkgs.system}.default;
    instances.dev = {
      enable = true;
      settings = {
        target = ".#dev";
        cpus = 4;
        memory = 4096;
        ports = [ ":8080" ];
        project_dir = "/home/alice/src/my-project";
      };
      hooks.post-launch."10-ready" = pkgs.writeShellScript "epi-ready" ''
        "$EPI_BIN" exec "$EPI_INSTANCE" -- touch /tmp/host-hook-ready
      '';
      hooks.pre-stop."10-sync" = pkgs.writeShellScript "epi-sync" ''
        "$EPI_BIN" exec "$EPI_INSTANCE" -- sync
      '';
    };
  };
}
```

This creates `epi-dev.service` in Alice's user systemd configuration. `settings` is the complete EPI TOML configuration, including `target`. Its configuration is rendered at `~/.config/epi/instances/dev.toml`; on first activation the service invokes `epi launch`, then uses `epi start` on later activations. If that rendered configuration changes, Hjem restarts the service; EPI force-removes the old instance and launches a replacement. Neither command has VM-setting flags. Hjem passes `settings.project_dir` directly to EPI; use an absolute path when the project is not relative to the generated configuration directory. The generated config defaults `default_name` to the instance name and disables automatic project mounting when `project_dir` is absent; override either through `settings`.

Set `instances.<name>.defaultState = "stopped"` to generate the instance configuration and service without adding the service to `default.target`. The instance then starts only when requested manually. Configuration switches preserve whether the service is active; changes to an active instance's rendered configuration still restart the service and reconcile the instance. The default is `"running"`, which retains automatic startup through `default.target`.

`hooks.post-launch`, `hooks.post-start`, and `hooks.pre-stop` are named maps of executable host script paths, also available through `settings.hooks`. Definitions merge using normal Nix module semantics. EPI saves the canonical paths at launch and GC-roots Nix store scripts for the lifetime of the instance, so later `start`, `stop`, and `upgrade` operations do not need the original Hjem configuration. `guest-init` is not supported in these settings.

### Projects

epi detects a project when `.epi/config.toml` exists in the current directory. A configured `project_dir` takes precedence over that detected directory; when it is absent, a detected project configuration keeps its existing directory fallback. Without either configuration source, EPI has no project identity. When a project directory is resolved:

- The project directory is automatically mounted into the guest (disable with `project_mount = false` or `--no-project-mount`); an explicit mount of the same canonical host source, including one with a guest destination, prevents a duplicate mount
- The project directory path is recorded in instance state and shown in `info` and `list` output
- `default_name` from the project config becomes the default instance name, so you can run `epi launch` without specifying one

Mount paths in config are resolved relative to the project root for `.epi/config.toml` and relative to the file directory for an `EPI_PROJECT_CONFIG_FILE` override, so `mounts = ["data"]` in `.epi/config.toml` mounts `<project>/data`. Tilde (`~/`) paths are expanded.

By default a mount is writable and placed in the guest at the same path as the host source. Append `:<dst>` to mount somewhere else, e.g. `--mount ./data:/workspace` or `mounts = ["data:/workspace"]`. Append `:ro` to make an explicit mount read-only, e.g. `--mount ./data:ro`, `--mount ./data:/workspace:ro`, or `mounts = ["data:/workspace:ro"]`. On Linux, read-only mounts use both the guest `ro` mount option and `virtiofsd --readonly`, so guest root cannot regain write access by remounting the filesystem. macOS rejects read-only mounts because the VZ backend cannot provide equivalent host enforcement. Automatic project mounts remain writable; disable `project_mount` and declare the project directory explicitly to make it read-only. The destination accepts an absolute guest path, `~`, or `~/path`; destination `~` expands to the configured guest user's home, while source `~` expands to the host home. Quote CLI arguments to let EPI handle expansion, e.g. `--mount '~/.local/state/paseo/sower:~/.local/state/paseo:ro'`. Overriding the destination also disables the automatic bind into the guest home for mounts under the host home directory (see the Changelog for that default behavior).

### Project initialization

```bash
epi init
```

Interactively creates a `.epi/config.toml` with target selection and default settings. `target` and `ports` are optional — leave either empty and the field is omitted, so the project inherits the target from your user config. Ports are entered as a space-separated list of `HOST:GUEST` or `:GUEST` mappings, e.g. `:8080 3000:3000`.

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

epi supports hook scripts at four points in the instance lifecycle. Each host-side hook point (`post-launch`, `post-start`, and `pre-stop`) executes in this order:

1. **User hooks** — `~/.config/epi/hooks/<hook>.d/`
2. **Project hooks** — `.epi/hooks/<hook>.d/`
3. **Configured host hooks** — named paths in user/project TOML under `hooks.post-launch`, `hooks.post-start`, and `hooks.pre-stop`
4. **Nix hooks** — declared in the nixosConfiguration via `epi.hooks.<hook>`

Filesystem hooks are sorted by filename; each filesystem layer also supports instance-specific subdirectories (`<hook>.d/<instance-name>/`) whose scripts run after the layer's top-level scripts. Non-executable filesystem hooks produce a warning and are skipped. Configured and Nix hooks run in lexical key order. Configured scripts must be executable; execution errors fail the command.

```toml
[hooks.post-launch]
"10-ready" = "scripts/ready"

[hooks.post-start]
"10-ready" = "scripts/on-start"

[hooks.pre-stop]
"10-sync" = "scripts/sync"
```

Configured hook maps merge per hook point, with project entries overriding user entries of the same name. Relative paths use each configuration file's directory, except the default `.epi/config.toml`, which uses the project root; `~/` expands to the host home. At launch, paths are canonicalized (including symlinks) and saved in instance state. Later lifecycle operations use those saved paths even if configuration files change or disappear. Nix store paths remain GC-rooted while the instance exists, including while stopped, and are released by `rm`. Local scripts must remain available at their canonical paths.

### post-launch

Runs on the **host** after the VM is reachable via SSH on `launch`, `rebuild`, and `upgrade --mode boot`, but not on ordinary `start`. `--no-provision` skips these hooks on launch. Useful for provisioning the guest from the outside (e.g. copying dotfiles, running commands over SSH).

Scripts receive the following environment variables:

| Variable | Description |
|---|---|
| `EPI_INSTANCE` | Instance name |
| `EPI_SSH_HOST` | SSH host (`127.0.0.1` on Linux; the guest's IP on macOS) |
| `EPI_SSH_PORT` | SSH port (forwarded localhost port on Linux; the guest's sshd port on macOS) |
| `EPI_SSH_KEY` | Path to the SSH private key |
| `EPI_SSH_USER` | SSH username |
| `EPI_STATE_DIR` | Instance state directory |
| `EPI_BIN` | Path to the running epi binary |

For portable guest access from a hook, prefer `$EPI_BIN exec "$EPI_INSTANCE" -- …`, or connect with `$EPI_SSH_HOST`/`$EPI_SSH_PORT` rather than assuming `localhost`.

If any hook exits non-zero, execution stops and the error is reported.

Since hooks run on the host (not inside the VM), use `$EPI_BIN exec` to run commands in the guest:

```bash
jq '{oauthAccount,userID,theme,firstStartTime,installMethod,hasCompletedOnboarding}' ~/.claude.json \
  | "$EPI_BIN" exec "$EPI_INSTANCE" -- "cat > .claude.json"
```

### post-start

Runs on the **host** after `post-launch` completes on `launch`, and after SSH readiness and host key trust on each later `start`. It receives the same environment variables and uses the same hook-layer ordering as `post-launch`. Useful for work needed whenever the instance is started, without repeating provisioning.

`launch --no-provision` and `start --no-provision` skip SSH readiness, host key trust, and both post hook points. Starting an already-running instance runs neither hook point. `rebuild` and `upgrade --mode boot` run `post-launch`, not `post-start`.

If a `post-launch` hook fails, `post-start` does not run. If a `post-start` hook fails, remaining hooks are skipped and the command reports the error. In both cases, the VM remains running; hooks are not rolled back.

### guest-init

Runs **inside the guest VM** on first boot only, as the provisioned user, after user creation, hostname, SSH keys, and mounts are configured. Network connectivity is available. Useful for installing packages or configuring the guest environment.

File-based hooks (from user and project layers) are embedded in the seed ISO at launch time. Nix-declared hooks are baked into the VM image. Seed ISO hooks run first, then Nix hooks. If a hook fails, the failure is logged and remaining hooks continue. SSH is available before hooks finish — they do not block the boot.

### pre-stop

Runs on the **host** before the VM is stopped. Useful for cleanup tasks like syncing data or saving state.

Receives the same environment variables as post-launch hooks. Runs on a normal `stop` and before an `upgrade --mode boot` restart; `stop --force` skips it. If any hook exits non-zero, execution stops and the error is reported without stopping the VM.
