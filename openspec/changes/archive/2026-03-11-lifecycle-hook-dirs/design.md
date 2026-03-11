## Context

epi has no mechanism for users to run custom scripts during the VM lifecycle. Users who need post-launch setup (host-side) or guest initialization beyond what NixOS config provides have to manually run commands after `epi launch`. The existing config system already supports three layers (user → project → instance), establishing a precedent for layered discovery.

## Goals / Non-Goals

**Goals:**
- Drop-in script directories for host-side lifecycle hooks and guest-side init hooks
- Three-layer discovery: user-level (`~/.config/epi/hooks/`), project-level (`.epi/hooks/`), per-instance (subdirectory named after the instance)
- Guest hooks run as the provisioned user
- Host hooks receive environment variables describing the instance

**Non-Goals:**
- Config-based inline hook commands (hook scripts must be files in directories)
- Hook scaffolding CLI commands (users create directories and scripts themselves)
- Async or parallel hook execution
- Hook failure policies (fail-fast is the only behavior)
- Guest hooks that run on every boot (only during init, same as epi-init)

## Decisions

**Drop-in directories as the sole hook mechanism.** Scripts live in well-known directories, not referenced by path in config. This avoids broken references — the scripts *are* the configuration. No indirection, `ls` shows what's configured.

*Alternative: config-based hook commands.* Rejected — introduces path resolution ambiguity (relative to what?) and broken references when scripts move.

**Three-layer directory structure with instance subdirectories.** Within each hook point directory, top-level executable files apply to all instances. Subdirectories named after instances contain scripts that only run for that instance. This reuses the existing config layering concept (user → project → instance) without needing separate config files.

```
~/.config/epi/hooks/post-launch.d/
  setup-tunnel.sh           # runs for all instances, all projects
  dev/
    notify.sh               # runs only for instance "dev"
.epi/hooks/post-launch.d/
  check-deps.sh             # runs for all instances in this project
  dev/
    seed-db.sh              # runs only for instance "dev" in this project
```

Execution order: user `*` → user `<instance>/*` → project `*` → project `<instance>/*`. Lexically sorted within each group.

*Alternative: separate directory trees per layer.* Rejected — too many directories. The nested approach keeps related hooks together.

**Guest hooks embedded in seed ISO.** Guest hook scripts are collected at provision time and written into the seed ISO alongside `epi.json`. The `epi-init` service extracts and executes them. This matches the existing pattern (seed ISO as the delivery mechanism) and avoids coupling hook execution to virtiofs mount availability during early boot.

*Alternative: virtiofs-mounted hook directory.* Rejected — virtiofs mounts happen during epi-init, so hooks that run during init can't rely on mounts being available yet.

**Guest hooks run as the provisioned user.** Most guest hooks are user-space tasks (dotfiles, tool setup, repo cloning). Running as root and requiring `su` for every user-space operation is more friction than running as user and requiring `sudo` for the rare root case.

**Host hooks receive instance metadata via environment variables.** Scripts get `EPI_INSTANCE`, `EPI_SSH_PORT`, `EPI_SSH_KEY`, `EPI_SSH_USER`, and `EPI_STATE_DIR` so they can interact with the VM without parsing state files.

**Hooks run any executable file.** All non-dotfile, non-directory entries are candidates. Scripts must be executable; non-executable files are skipped with a warning.

## Risks / Trade-offs

- [Instance subdirectory collides with a script name] → Not possible since scripts require `.sh` extension and directories don't have extensions.
- [Guest hooks fail silently inside VM] → Hook execution output should be visible in the serial console log. epi-init should exit non-zero if a hook fails, which will be visible via `epi console`.
- [Large number of hook scripts slows down launch] → Hooks run sequentially; this is inherent to the design. Users control what they put in the directories.
- [Hook scripts not executable] → Skip non-executable files with a warning to stderr rather than failing the entire launch.
