## Context

epi manages three categories of background processes per VM instance: cloud-hypervisor (the VM), passt (userspace networking), and virtiofsd (host filesystem sharing). Currently these are spawned via `Process.run_detached` which does fork+setsid+execvpe, storing the resulting PIDs in a plain-text runtime file. Liveness is checked via signal-0 (`kill pid 0`), and a reconciliation pass runs on every command to clean up stale PIDs and orphaned children.

This works but has known fragility: PID files can become stale after crashes, orphaned child processes (passt/virtiofsd) linger when the VM dies unexpectedly, and the reconciliation loop adds latency and complexity to every command invocation. Since epi runs on NixOS (systemd-based Linux), we can delegate process lifecycle to systemd's existing infrastructure.

## Goals / Non-Goals

**Goals:**
- Eliminate PID tracking and signal-0 liveness checks in favor of systemd unit status queries
- Get automatic cleanup of child processes when the VM dies (cgroup-based)
- Remove the reconciliation loop from command startup
- Preserve all existing CLI behavior (launch, stop, status, console, ssh, rm)
- Keep process logs accessible (journald replaces stdout/stderr log files)

**Non-Goals:**
- Automatic restart of crashed processes (supervisor/watchdog behavior) — epi remains a launcher, not a service manager
- System-level units requiring root — all units are `--user` scope
- Supporting non-systemd Linux — this is a hard dependency on systemd
- Changing guest-side behavior — only host-side process management changes

## Decisions

### Escape instance names for systemd unit names using `systemd-escape`

Systemd unit names only allow ASCII letters, digits, underscores, and hyphens — and hyphens in slice names have special meaning as hierarchy separators (e.g., `epi-dev-a.slice` creates `epi.slice → epi-dev.slice → epi-dev-a.slice` with phantom intermediates). Instance names are user-provided and may contain hyphens or other characters.

The CLI SHALL run `systemd-escape <instance-name>` to produce a systemd-safe encoding of the instance name, then use that escaped string when constructing unit names. `systemd-escape` is a bijection — different inputs always produce different outputs — so uniqueness is guaranteed.

Example: instance `dev-a` → escaped `dev\x2da` → slice `epi-dev\x2da.slice` (direct child of `epi.slice`, no phantom intermediates).

**Alternative considered:** Validating instance names at creation time to reject special characters. Rejected because it would break existing instances with hyphens (like `dev-a`) and is unnecessarily restrictive when `systemd-escape` handles it cleanly.

### Include a random session ID in unit names to prevent collisions

Each launch generates a short random hex ID (e.g., 8 characters). This ID is embedded in all unit names for that launch session and stored in the runtime file as `unit_id`. This prevents collisions when:

- A previous launch's systemd units are still running but the runtime file was lost/corrupted
- `systemd-run` would otherwise fail with "Unit already exists" on a re-launch

Before launching, the CLI attempts a best-effort stop of any existing slice for the instance (using the stored `unit_id` from the old runtime, if available). Then it generates a fresh ID for the new launch.

### Use systemd transient units for each process, grouped under a per-instance slice

All processes run as transient **services** (`systemd-run --user`), grouped under a per-instance slice. Unit names use the escaped instance name plus the session ID:

```
epi-<escaped>-<id>.slice
  ├── epi-<escaped>-<id>-vm.service        (cloud-hypervisor — with ExecStopPost)
  ├── epi-<escaped>-<id>-passt.service     (passt)
  ├── epi-<escaped>-<id>-virtiofsd-0.service (first virtiofsd)
  └── epi-<escaped>-<id>-virtiofsd-1.service (second virtiofsd, etc.)
```

**Why services for all processes?** Services support `StandardOutput=file:` and `StandardError=file:` for log redirection, which scopes do not. The VM service additionally has `ExecStopPost=` to tear down the entire slice when cloud-hypervisor exits for any reason (crash, guest shutdown, explicit stop). The VM service is created with:

```
systemd-run --user --collect --unit=epi-<escaped>-<id>-vm --slice=epi-<escaped>-<id> \
  --property=Type=exec \
  --property="ExecStopPost=/run/current-system/sw/bin/systemctl --user stop epi-<escaped>-<id>.slice" \
  --setenv=... \
  -- cloud-hypervisor ...
```

This uses the NixOS absolute path `/run/current-system/sw/bin/systemctl` since `ExecStopPost=` does not inherit the user's `$PATH`. The `--setenv` flags pass the caller's environment to the service, since transient services don't inherit the parent's environment.

After starting the VM service, the launcher waits briefly and verifies the unit is still active. This detects immediate failures (e.g., exec error, lock conflict) that `systemd-run` wouldn't report since it returns success after creating the unit.

**Why a slice?** Slices give us `systemctl --user stop epi-<escaped>-<id>.slice` to tear down everything atomically. The `ExecStopPost` on the VM service uses this same mechanism, so both explicit `epi down` and unexpected VM exits cascade to all helpers.

**Alternative considered:** Using `--property=BindsTo=` to chain passt/virtiofsd lifetimes to the VM unit. Rejected because BindsTo implies a start dependency — helpers need to start *before* the VM (it connects to their sockets), but BindsTo would try to pull the VM in when helpers start, creating ordering issues.

### Shell out to `systemd-run` and `systemctl` via `Process.run`

Rather than binding to libsystemd/sd-bus from OCaml, invoke `systemd-run` and `systemctl` as subprocesses. This avoids adding C bindings or new OCaml dependencies and matches the existing pattern of shelling out to `cloud-hypervisor`, `passt`, etc.

**Alternative considered:** Using sd-bus D-Bus protocol directly. Rejected because it would require OCaml D-Bus bindings (not readily available), and the subprocess approach is simpler with negligible overhead for the few calls we make.

### Replace PID fields in runtime with a stored unit ID

The runtime type drops `pid`, `passt_pid`, and `virtiofsd_pids` and adds `unit_id` (the random session ID). Liveness is determined by constructing the VM service name from the escaped instance name + unit_id and querying `systemctl --user is-active`.

The runtime file retains: `unit_id`, `serial_socket`, `disk`, `ssh_port`, `ssh_key_path`.

### Remove reconcile_runtime entirely

Since systemd tracks process state, there's no stale PID data to clean up. If the VM scope is inactive, systemd already knows. The serial socket file still needs cleanup, but this can happen lazily at launch time (delete before creating) rather than eagerly on every command.

### Use `systemd-run` with `--collect` flag

The `--collect` flag ensures the transient unit is garbage-collected after the process exits, preventing accumulation of dead units in `systemctl --user list-units`.

### Redirect stdout/stderr via systemd properties

Use `--property=StandardOutput=file:<path>` and `--property=StandardError=file:<path>` to maintain the existing log file locations, preserving compatibility with `epi logs` and debugging workflows. This is preferred over journald-only logging since users expect log files at known paths.

## Risks / Trade-offs

- **systemd dependency** → epi already targets NixOS exclusively; systemd is always present. Document the requirement in the README.
- **User session not active** → `systemd-run --user` requires an active user session. If run via cron or SSH without lingering, units may fail to start. → Mitigate by detecting this failure and printing actionable guidance ("run loginctl enable-linger").
- **Stopping a slice kills ALL child processes** → This is the desired behavior, but if a user manually starts additional processes under the slice, those die too. → Acceptable since the slice name is epi-specific and unlikely to be used externally.
- **Log file rotation** → `StandardOutput=file:` truncates on each start (like current behavior). No change in behavior, but worth noting that append mode (`append:`) is available if needed later.
