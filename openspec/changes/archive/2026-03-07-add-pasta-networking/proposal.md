## Why

The current VM networking uses TAP interfaces (`--net tap=`), which requires CAP_NET_ADMIN or root privileges on the host. This blocks unprivileged developers from running `epi up` without elevated permissions. Switching to pasta (part of the passt project) provides userspace networking that works without special privileges, making the developer workflow accessible on any standard user account.

## What Changes

- Replace the `--net tap=` cloud-hypervisor argument with a pasta-backed network configuration
- Add pasta as a runtime dependency and wire it into the Nix packaging
- Expose a `pasta` binary path option (env var override) for cloud-hypervisor's `--net` flag
- Update the manual-test NixOS configuration if any guest-side changes are needed for pasta networking
- Update tests to reflect the new network argument format

## Capabilities

### New Capabilities
- `pasta-networking`: Userspace network access for VMs via pasta, replacing TAP-based networking so VMs can be launched without root privileges

### Modified Capabilities
- `nixos-manual-test-config`: Network connectivity requirement changes from TAP-based to pasta-backed virtio-net; DHCP behavior stays the same but the underlying transport changes
- `vm-provision-from-target`: VM launch arguments change to use pasta instead of TAP for the `--net` flag

## Impact

- **Code**: `vm_launch.ml` launch arguments change; new env var for pasta binary path
- **Dependencies**: `passt` package added to runtime dependencies in `package.nix` and `flake.nix`
- **Tests**: `test_epi.ml` assertions on `--net` argument format need updating
- **Privileges**: VMs no longer require root/CAP_NET_ADMIN to start — this is the primary user-facing improvement
