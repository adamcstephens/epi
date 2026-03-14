## Why

The current console capture runs as a background thread inside the `epi launch` CLI process. When `epi launch` exits, the thread dies, so console.log only contains boot output — shutdown messages are never captured. This makes it impossible to verify graceful guest shutdown or diagnose shutdown failures. Additionally, the graceful shutdown mechanism has two bugs: the ExecStop script's shebang fails in systemd's minimal environment, and `stop_instance` stops the slice (killing processes immediately) instead of the VM service (which triggers ExecStop).

## What Changes

- Use cloud-hypervisor's `--console file=<path>` to write console output to a file natively, replacing the in-process serial capture thread. The file is written by cloud-hypervisor itself, so it persists for the full VM lifecycle including shutdown.
- Keep `--serial socket=<path>` for interactive `epi console` attachment (unchanged).
- Add `console=hvc0` as the last console in the kernel cmdline (ordering: `console=ttyS0 console=hvc0`) so hvc0 is the primary `/dev/console` and receives all systemd boot/shutdown output for file capture. ttyS0 still receives kernel printk and runs a serial getty for interactive use.
- Remove the `start_capture` background thread and its call sites.
- Add `console_log` path to `CloudHypervisorConfig` for the `--console file=` argument.
- Fix graceful shutdown: resolve `sh` to an absolute path in the shutdown script shebang.
- **BREAKING**: `stop_instance` stops the VM service first (triggering ExecStop for graceful ACPI shutdown), then stops the slice for helper cleanup. Previously it only stopped the slice.
- Make the `shutdown-vmm` fallback non-fatal (`|| true`) since it returns non-zero when the VM has already exited cleanly.

## Capabilities

### New Capabilities
- `console-file-capture`: Cloud-hypervisor writes console output to a file via `--console file=`, capturing the full VM lifecycle including shutdown.

### Modified Capabilities
- `vm-detached-serial-console`: Console capture is no longer done by a background thread; the `start_capture` function and its call sites are removed.
- `vm-stop-ordering`: `stop_instance` stops the VM service before the slice to trigger ExecStop graceful shutdown.

## Impact

- `src/cloud_hypervisor.rs`: Add `console_log` field to config, change `--console off` to `--console file=`, fix shutdown script shebang and `|| true`.
- `src/console.rs`: Remove `start_capture` function.
- `src/vm_launch.rs`: Pass `console_log` (console.log) to ch config, resolve `sh` binary path, fix `stop_instance` to stop VM service before slice.
- `src/main.rs`: Remove `start_capture` call sites.
- `nix/nixos/epi.nix`: Update cmdline default to `console=ttyS0 console=hvc0`, add `virtio_console` to `availableKernelModules`.
