## Context

The current virtiofs-mount implementation supports a single `--mount` flag that shares one host directory with the guest. Each mount requires its own `virtiofsd` daemon process (one daemon per shared directory is the virtiofsd model). The instance runtime state (`instance_store.ml`) currently tracks a single `virtiofsd_pid : int option`.

The change must extend the flag to be repeatable, fan out daemon start/stop, and produce multiple cloud-init mount entries.

## Goals / Non-Goals

**Goals:**
- Allow `--mount` to be specified multiple times on `epi up`
- Start one `virtiofsd` process per mount path, each with a unique socket and virtiofs tag
- Include all mount entries in cloud-init user-data
- Track all virtiofsd PIDs and terminate them all on `epi down`

**Non-Goals:**
- Hot-adding mounts to a running VM
- Named/custom tags for virtiofs shares (paths continue to be the only identifier)
- Deduplicating identical mount paths passed multiple times

## Decisions

### 1. CLI: `--mount` becomes a multi-value flag

`Cmdliner` supports repeated flags via `Arg.opt_all`. Change `mount_path : string option` to `mount_paths : string list` throughout. An empty list means no mounts (replacing `None`).

**Alternative considered**: `--mount a,b` comma-separated. Rejected because paths can contain commas and repeated flags are the POSIX convention.

### 2. Socket and tag naming: index-based

Each mount gets a unique socket path `<instance_dir>/virtiofsd-<n>.sock` and virtiofs tag `hostfs-<n>` where `<n>` is the zero-based index into the mount list. This is simple and deterministic.

**Alternative considered**: Hash of the path. Rejected as overly complex; the list order is stable within a single `epi up` invocation.

### 3. Instance state: `virtiofsd_pids : int list`

Replace `virtiofsd_pid : int option` with `virtiofsd_pids : int list` in `Instance_store.runtime`. The serialisation format changes from `virtiofsd_pid=N` to `virtiofsd_pids=N,M,...` (comma-separated, omitted when empty).

**Migration**: Existing state files with `virtiofsd_pid=N` will be read by a compatibility path that promotes the single value into a one-element list. No migration action required from users.

### 4. Cloud-init: one `mounts` entry per path

`generate_user_data` iterates the mount list and emits one systemd `.mount` unit entry per path, same format as the current single-mount code.

## Risks / Trade-offs

- [Multiple virtiofsd processes] Each process is ~10 MB RSS and holds the shared directory open. Mitigation: no practical limit imposed; this matches existing single-daemon behaviour scaled up.
- [State file compatibility] Old instances with `virtiofsd_pid=N` in their state file will be correctly parsed via the compatibility path, but `epi down` will use the new `virtiofsd_pids` code path.
