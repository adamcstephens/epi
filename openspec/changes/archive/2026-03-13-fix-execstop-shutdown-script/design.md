## Context

The VM service's ExecStop commands fail because systemd cannot find `ch-remote`, `timeout`, or `tail` — `--setenv` only applies to `ExecStart`, not control commands like `ExecStop`. The graceful shutdown sequence (ACPI power-button → wait → force shutdown-vmm) never executes, so VMs are killed immediately on stop.

## Goals / Non-Goals

**Goals:**
- ExecStop graceful shutdown works reliably by ensuring all binary paths are resolved at launch time
- Same shutdown behavior: power-button, wait up to 15s, shutdown-vmm fallback

**Non-Goals:**
- Changing the shutdown sequence logic itself
- Changing how `epi stop` invokes systemd (still stops the slice)

## Decisions

### Generate a shutdown script instead of using inline ExecStop commands

Write a `shutdown.sh` script to `<instance-dir>/shutdown.sh` at launch time with absolute paths baked in. Use a single `ExecStop=<instance-dir>/shutdown.sh` on the service.

Alternative: resolve absolute paths and use them directly in three `ExecStop=` properties. Rejected because a single script is simpler to debug (you can read it, run it manually) and avoids questions about how systemd handles `$MAINPID` expansion across multiple ExecStop lines.

### Resolve binary paths using existing `find_executable` at launch time

`process::find_executable` already resolves binaries via PATH. Make it `pub` and use it to resolve `ch-remote`, `timeout`, and `tail` at launch time. If any binary is missing, fail the launch with a clear error rather than discovering the problem at stop time.

Alternative: hardcode nix store paths. Rejected because the paths change with package updates and the project already has a pattern for runtime resolution.

### Store the script in the instance directory

The script is instance-specific (contains the API socket path) and should be cleaned up with the instance. `<instance-dir>/shutdown.sh` is the natural location.

## Risks / Trade-offs

- [Risk] Binary paths could change between launch and stop (e.g., `nix-collect-garbage` between launch and stop) → Unlikely in practice; same risk already exists for the CH binary itself.
- [Risk] Script must be executable → Set permissions at write time.
