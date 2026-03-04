## Context

`vm_launch.ml` starts a passt process for userspace networking and discards its pid. `Instance_store.runtime` only tracks `{ pid; serial_socket; disk }` — all hypervisor-centric fields. Nothing terminates pasta on `down`, `rm`, or stale-entry cleanup.

## Goals / Non-Goals

**Goals:**
- Store pasta_pid in `Instance_store.runtime` alongside the hypervisor pid
- Kill pasta in every path that terminates or clears an instance: `down`, `rm --force`, `reconcile_runtime` stale cleanup, and `up` when relaunching over a stale entry
- Backward-compatible state file parsing (rows without pasta_pid field parse as `None`)

**Non-Goals:**
- Waiting for pasta to confirm clean shutdown (SIGTERM, best-effort)
- Tracking multiple pasta processes per instance
- Surfacing pasta_pid in `epi status` output

## Decisions

### Decision: Add `pasta_pid : int option` to `Instance_store.runtime`

`int option` rather than `int` because existing persisted state rows have no pasta_pid field; they should parse cleanly as `None`. Instances launched during the transition window (or without pasta) can still be terminated via the hypervisor pid alone.

### Decision: Extend state file with a 6th tab-separated field

Current row format: `instance_name\ttarget\tpid\tserial_socket\tdisk`
New row format: `instance_name\ttarget\tpid\tserial_socket\tdisk\tpasta_pid`

Parser updated to handle both 5-field (old) and 6-field (new) rows. Empty pasta_pid field (or missing) → `None`. No migration needed; old rows work transparently.

### Decision: Kill pasta in `terminate_instance_runtime`, not in a separate helper

`terminate_instance_runtime` in `epi.ml` is the single place that sends SIGTERM to the hypervisor. Adding a best-effort SIGTERM to `pasta_pid` there keeps the kill logic co-located. No waiting loop needed for pasta — it exits promptly when the vhost-user connection drops (hypervisor is already dead by this point).

### Decision: `reconcile_runtime` kills pasta for stale entries

When `reconcile_runtime` finds a dead hypervisor pid, it currently just clears the runtime entry. It should also fire a best-effort `kill(pasta_pid, SIGTERM)` before clearing. This handles the case where pasta outlived the hypervisor (e.g. cloud-hypervisor crashed).

### Decision: `up` kills stale pasta before relaunching

The `up` command already calls `reconcile_runtime` first (which handles the normal stale-pid case). For the explicit stale-runtime relaunch path (`Some _stale_runtime → clear_runtime → launch`), we kill any `pasta_pid` in the stale runtime before clearing it, as a defense against reconcile races.

## Risks / Trade-offs

- **[pasta_pid not always present]** → `None` case is handled throughout; pasta kill is skipped gracefully
- **[pasta already dead when we kill it]** → `Unix.kill` on a dead pid returns `ESRCH`; catch and ignore
- **[state file written by old binary, read by new]** → old 5-field rows parse as `pasta_pid = None`; safe
- **[state file written by new binary, read by old]** → old parser splits on tab; a 6-field row may fail to parse cleanly in old code. Acceptable for a single-user CLI tool with no concurrent binary versions.
