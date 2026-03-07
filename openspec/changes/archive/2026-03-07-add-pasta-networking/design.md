## Context

Currently `epi up` launches cloud-hypervisor with `--net tap=`, which relies on TAP interfaces requiring CAP_NET_ADMIN or root privileges. This prevents unprivileged users from running VMs. The passt/pasta project provides userspace networking that translates between a VM's virtio-net device and the host's TCP/IP stack without elevated privileges.

cloud-hypervisor supports pasta natively via `--net socket=` with a pasta-spawned file descriptor, or more simply via the `--net tap=,ip=,mask=` arguments with pasta handling the TAP setup in userspace. However, the simplest integration path is cloud-hypervisor's built-in support for connecting to a pasta process via its fd-passing mechanism — but the most straightforward approach for our use case is to let pasta create and manage the TAP device itself.

## Goals / Non-Goals

**Goals:**
- VMs launch with network access without requiring root or CAP_NET_ADMIN
- pasta binary is available as a runtime dependency
- Existing DHCP-based guest networking continues to work unchanged
- pasta binary path is overridable via environment variable for flexibility

**Non-Goals:**
- Custom network topologies or port forwarding configuration
- Multi-VM network isolation or inter-VM networking
- IPv6-specific configuration (pasta passes through IPv6 by default)
- Performance tuning of pasta networking

## Decisions

### Decision: Use `pasta` as the network backend via cloud-hypervisor's `--net` flag

cloud-hypervisor supports specifying an external program to set up the TAP device. By passing pasta's fd to cloud-hypervisor, the TAP device is created in a user namespace without privileges.

**Approach**: Use `--net tap=,socket=/path/to/pasta.socket` or invoke pasta to get an fd and pass it to cloud-hypervisor. The cleanest integration is to use pasta in "pasta mode" (as opposed to passt's socket mode) where pasta wraps the process and provides network namespace translation.

**Alternative considered**: slirp4netns — older, slower, and less maintained than pasta. pasta is the modern replacement with better performance and active development.

**Alternative considered**: passt socket mode — requires managing a separate long-running passt daemon process and connecting cloud-hypervisor via a Unix socket. More complex lifecycle management for no clear benefit in our single-VM use case.

### Decision: Add `EPI_PASTA_BIN` environment variable

Follows the existing pattern of `EPI_CLOUD_HYPERVISOR_BIN` and `EPI_GENISOIMAGE_BIN` for overriding tool paths. Defaults to finding `pasta` on `PATH`.

### Decision: Add passt to devShell and note it as a runtime dependency

Add `passt` to the devShell packages in `flake.nix` so it's available during development. The statically-linked epi binary expects pasta on PATH at runtime, matching the existing pattern for cloud-hypervisor and genisoimage.

### Decision: Change `--net` argument from `tap=` to pasta-backed format

Replace the hardcoded `"--net"; "tap="` in `vm_launch.ml` with the pasta-backed equivalent. cloud-hypervisor's documentation specifies using `--net tap=,socket=<fd>` when pasta provides the fd. The exact flag format will be confirmed during implementation against cloud-hypervisor's current API.

## Risks / Trade-offs

- **[pasta not available on all systems]** → pasta is packaged in nixpkgs as `passt`; by adding it to the devShell and documenting it as a runtime dep, availability is handled for Nix users. Non-Nix users need to install it separately.
- **[Networking behavior differences]** → pasta uses DHCP internally to assign addresses, matching our current virtio-net + DHCP setup. Guest-side config should not need changes. Verify in manual testing.
- **[cloud-hypervisor + pasta integration specifics]** → cloud-hypervisor's `--net` flag syntax for pasta may vary by version. Pin to the behavior in nixpkgs-unstable's cloud-hypervisor package.
