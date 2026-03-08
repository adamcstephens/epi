## Why

Development workflows require editing code on the host while running/testing inside the VM. Currently there's no way to share host directories with the guest, forcing users to either SSH+rsync files or rebuild the entire VM image. Virtiofs provides near-native filesystem performance for host-to-guest sharing, making it ideal for mounting the current project into the VM.

## What Changes

- Start a `virtiofsd` daemon alongside the VM, exposing a host directory via a vhost-user socket
- Pass `--fs` argument to `cloud-hypervisor` to attach the virtiofs share to the guest
- Add `virtiofs` to guest kernel modules in `epi.nix` (always available, zero cost when unused)
- Configure the mount at runtime via cloud-init `mounts` directive (only when `--mount` is used); guest mount point mirrors the host path so paths work identically on both sides
- Add a `--mount` CLI flag to `epi up` specifying the host directory to share (defaults to current working directory)
- Store virtiofsd PID in instance runtime state for cleanup on `epi down`

## Capabilities

### New Capabilities
- `virtiofs-mount`: Host directory sharing into the VM via virtiofsd, including daemon lifecycle, cloud-hypervisor `--fs` integration, and cloud-init runtime mount configuration

### Modified Capabilities
_None_

## Impact

- **Code**: `vm_launch.ml` (virtiofsd daemon start, `--fs` arg, cloud-init mount entry), `epi.ml` (new `--mount` flag on `up` command), `instance_store.ml` (virtiofsd PID tracking), `epi.nix` (virtiofs kernel module)
- **Dependencies**: Requires `virtiofsd` binary available on host (similar pattern to `passt` dependency)
- **APIs**: New optional `--mount` flag on `epi up`; no breaking changes
