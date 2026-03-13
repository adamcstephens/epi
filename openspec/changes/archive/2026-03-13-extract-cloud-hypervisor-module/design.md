## Context

`vm_launch.rs` currently handles everything: disk prep, SSH keys, seed ISO, helper processes, CH argument construction, and VM lifecycle. The CH-specific code (lines 139–198) builds a ~20-argument command line with format strings for disk, memory, CPU, serial, network, and filesystem arguments. The upcoming graceful-shutdown change adds API socket management and ExecStop property generation, making the CH surface area larger.

## Goals / Non-Goals

**Goals:**
- Isolate cloud-hypervisor CLI knowledge into `src/cloud_hypervisor.rs`
- Provide a clear boundary: `vm_launch.rs` prepares inputs (paths, ports, descriptors), `cloud_hypervisor` turns them into CH arguments and systemd properties
- Make the graceful-shutdown change land cleanly on top

**Non-Goals:**
- Abstracting over different hypervisors (only CH is supported)
- Moving helper process logic (passt, virtiofsd) — these stay in `vm_launch.rs`
- Changing any external behavior

## Decisions

### Module exposes `build_args` that returns a Vec of CH CLI arguments

The function takes structured inputs (disk path, seed ISO, descriptor fields, socket paths) and returns `Vec<String>`. This avoids vm_launch needing to know CH's CLI syntax.

Alternative: Pass the entire Descriptor plus paths as a struct. Rejected because it couples the module to instance_store types and the struct would just mirror the function parameters.

### Module exposes `exec_stop_properties` for graceful shutdown

Takes the API socket path, helper unit names, and returns `Vec<String>` of systemd property strings (ExecStop, ExecStopPost, After, TimeoutStopSec). This keeps systemd property construction co-located with the CH knowledge that motivates it.

### Binaries referenced by name, resolved via PATH

`cloud-hypervisor` and `ch-remote` are used by name, relying on PATH resolution at runtime. This is consistent with how other dependent binaries (`passt`, `virtiofsd`, `qemu-img`, `xorriso`) work. The `EPI_*_BIN` env vars are only used for `systemctl` and `systemd-run` (test mocking); dependent binaries don't need them since they ship in nix packages on PATH.

## Risks / Trade-offs

- [Risk] Splitting a file adds indirection → Acceptable for a module with a clear single responsibility; the boundary is "everything that knows about cloud-hypervisor's CLI"
