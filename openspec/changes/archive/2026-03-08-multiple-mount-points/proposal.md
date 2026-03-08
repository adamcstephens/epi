## Why

The current `--mount` flag only supports a single host directory share. Users need to share multiple directories (e.g., a project directory and a secrets directory) without launching separate VM instances.

## What Changes

- `--mount` flag becomes repeatable: `epi up --mount /path/a --mount /path/b`
- Multiple virtiofsd daemons are started (one per mount), each with a unique socket and tag
- Cloud-init `mounts` block includes an entry for each mount path
- All virtiofsd processes are tracked and cleaned up on `epi down`

## Capabilities

### New Capabilities

None — this extends the existing `virtiofs-mount` capability.

### Modified Capabilities

- `virtiofs-mount`: Requirements change to support multiple `--mount` flags instead of a single one, with independent virtiofsd instances and cloud-init entries per mount.

## Impact

- CLI argument parsing for `--mount`
- Instance state: virtiofsd PID tracking must support a list
- Cloud-init user-data generation: `mounts` block must include all entries
- `epi down` cleanup: must terminate all virtiofsd processes
