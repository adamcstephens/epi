## Context

epi launches cloud-hypervisor VMs with passt networking and cloud-init provisioning. The VM is currently isolated — its only storage is the disk image. Developers need to share host directories (typically the current project) with the guest for edit-on-host, run-in-guest workflows.

Cloud-hypervisor supports virtiofs via `--fs` with a vhost-user backend. The standard backend is `virtiofsd`, which exposes a host directory over a Unix socket.

## Goals / Non-Goals

**Goals:**
- Mount a host directory into the guest VM with near-native performance
- Opt-in via `--mount` flag on `epi up` (no impact when unused)
- Clean lifecycle management (virtiofsd starts with VM, stops on `epi down`)
- Guest mount configured at runtime via cloud-init (no image rebuild needed for mount path changes)

**Non-Goals:**
- Multiple simultaneous mounts (single mount is sufficient for now)
- Write-back caching or tuning virtiofsd performance knobs
- Bidirectional sync or conflict resolution — virtiofs is a direct passthrough

## Decisions

### 1. virtiofsd as the vhost-user backend

**Choice**: Use `virtiofsd` (Rust implementation from the virtiofsd project).

**Rationale**: It's the standard virtiofs backend for cloud-hypervisor. Same vhost-user socket pattern already used for passt networking. No alternative backends provide meaningful advantages for this use case.

### 2. Guest mount via cloud-init `mounts` directive

**Choice**: Emit a `mounts:` block in the cloud-init user-data when `--mount` is used, rather than baking the mount into the NixOS config.

**Rationale**: The mount path and tag are runtime concerns. Cloud-init already handles dynamic provisioning (SSH keys, users). Adding `virtiofs` to `availableKernelModules` in `epi.nix` is the only image-time change needed — a one-liner with zero cost when no share is attached.

### 3. virtiofsd lifecycle follows passt pattern

**Choice**: Start virtiofsd as a detached process before cloud-hypervisor, wait for socket, store PID in runtime state, kill on `epi down`.

**Rationale**: This exactly mirrors how passt is managed today. Reusing the same pattern keeps the codebase consistent and the implementation straightforward.

### 4. Default mount source is current working directory

**Choice**: `--mount` with no argument uses `Sys.getcwd ()`. `--mount /path` uses the given path.

**Rationale**: The most common case is mounting the project you're working in. Explicit path supports other use cases without a separate flag.

### 5. Guest mount point mirrors host path

**Choice**: Mount to the same absolute path inside the guest as the source directory on the host. E.g. if host path is `/home/adam/projects/epi`, the guest mount point is `/home/adam/projects/epi`.

**Rationale**: Paths work identically on both sides — scripts, build tools, and editor integrations don't need path translation. Cloud-init's `mounts` directive combined with `runcmd` to `mkdir -p` the path handles arbitrary mount points.

## Risks / Trade-offs

- **virtiofsd availability**: Not all systems have virtiofsd installed → Same mitigation as passt: check binary existence, report clear error with `EPI_VIRTIOFSD_BIN` env var override.
- **Permission mapping**: virtiofsd maps UIDs between host and guest. Partially mitigated: when cloud-init creates the user (`user_exists = false`), set `uid: <host_uid>` from `Unix.getuid ()` so the guest user's UID matches the host. Files in the virtiofs mount then have correct ownership. When the user is pre-configured in the NixOS image, UIDs may still differ — acceptable for development workflows.
- **Cloud-init ordering**: The virtiofs device must be available before cloud-init runs `mount -a` → Cloud-hypervisor attaches the `--fs` device at boot, well before cloud-init's config stage.
