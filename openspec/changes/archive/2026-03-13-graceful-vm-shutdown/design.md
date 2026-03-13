## Context

Cloud-hypervisor (CH) does not handle SIGTERM. When `systemctl --user stop` is called on the instance slice, systemd sends SIGTERM to all processes simultaneously. CH ignores it and systemd waits 90s (`DefaultTimeoutStopSec`) before SIGKILL. Additionally, killing all processes simultaneously breaks CH's vhost-user sockets (passt, virtiofsd), causing CH to hang even if it did try to shut down.

CH provides an HTTP API socket (`--api-socket`) and a companion CLI tool `ch-remote` (shipped in the same nix package) for lifecycle control. The API supports `power-button` (ACPI shutdown to guest), `shutdown` (force VM stop, VMM stays alive), and `shutdown-vmm` (exit VMM process). When the guest shuts down, CH auto-exits via its exit event handler.

## Goals / Non-Goals

**Goals:**
- `epi rm -f` and `epi stop` complete within seconds, not 90s
- Give the guest OS a chance to shut down cleanly before force-killing
- Ensure helpers (passt, virtiofsd) stay alive until after CH exits, so CH can shut down without broken sockets

**Non-Goals:**
- Configurable shutdown timeout (hardcode 15s for now)
- Persisting the API socket path in runtime state (derivable from instance dir)
- Using the API socket for anything beyond shutdown (e.g., resize, snapshot)

## Decisions

### Use ch-remote via ExecStop rather than calling it from Rust

ExecStop commands run within the systemd service context, which means systemd manages the lifecycle and timeout. This avoids adding process-spawning logic to `stop_instance` and keeps the Rust code simple — it just stops the slice.

Alternative: Call `ch-remote` from Rust in `stop_instance`. Rejected because it duplicates systemd's job and requires manual timeout/polling logic in Rust.

### Use `tail --pid=$MAINPID` for waiting instead of a polling loop

`tail --pid=$MAINPID -f /dev/null` is a standard idiom for blocking until a process exits. Wrapped with `timeout 15`, it gives the guest up to 15s to shut down. This avoids writing a helper script or adding shell polling loops.

`$MAINPID` is expanded by systemd in ExecStop lines. `tail` and `timeout` are available via PATH forwarded from the user's environment.

### Add After= ordering instead of relying on ExecStopPost for helper cleanup

Adding `After=<helper>.service` to the VM service means systemd respects ordering during slice stop: VM stops first, then helpers. This ensures CH's vhost-user sockets remain alive during shutdown.

ExecStopPost is retained for the case where the VM exits on its own (crash, guest-initiated shutdown) — it still needs to clean up orphaned helpers.

### TimeoutStopSec=20s as safety net

The ExecStop sequence takes at most ~16s (power-button + 15s wait + shutdown-vmm). TimeoutStopSec=20s gives 4s of buffer. If everything fails, systemd SIGKILL after 20s.

## Risks / Trade-offs

- [Risk] `tail --pid` or `timeout` not in PATH within systemd service → Mitigated by forwarding the full user environment via `--setenv`
- [Risk] Guest ignores ACPI power-button (no ACPI support or hung guest) → `shutdown-vmm` fires after 15s as fallback, then SIGKILL after 20s
- [Risk] API socket not ready when ExecStop fires (race during very early shutdown) → `ch-remote` fails, ExecStop continues, TimeoutStopSec SIGKILL catches it
- [Trade-off] 15s wait adds latency to force-stop when guest doesn't respond cleanly. Acceptable since the alternative was 90s.
