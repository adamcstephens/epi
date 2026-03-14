## Context

Console output is currently captured by a background thread in the `epi launch` process that reads from the serial Unix socket and writes to `console.log`. This thread dies when `epi launch` exits, so only boot output is captured. Shutdown output is lost because no process is reading the serial socket when `epi stop` runs.

Cloud-hypervisor provides two independent console devices: `--serial` (16550 UART, ttyS0) and `--console` (virtio-console, hvc0). Each supports different backends (`off`, `null`, `pty`, `tty`, `file=`, and for serial only, `socket=`). We currently use `--serial socket=` for interactive attachment and `--console off`.

The graceful shutdown path also has two bugs: the ExecStop shutdown script uses `#!/usr/bin/env sh` which fails in systemd's minimal PATH, and `stop_instance` stops the systemd slice (immediate kill) instead of the VM service (which triggers ExecStop).

## Goals / Non-Goals

**Goals:**
- Capture complete console output including shutdown messages, written by cloud-hypervisor natively
- Preserve interactive `epi console` attachment via serial socket
- Fix graceful ACPI shutdown so `epi stop` cleanly shuts down the guest
- Remove the in-process capture thread (simplification)

**Non-Goals:**
- Multiplexing the serial socket for multiple simultaneous readers
- Adding a persistent daemon process for capture
- Changing the interactive console escape sequence or behavior

## Decisions

### Use `--console file=` for capture, keep `--serial socket=` for interactive

Cloud-hypervisor's `--console` device supports `file=` mode, writing all output directly to disk. By using `--console file=<console.log>` alongside `--serial socket=<serial.sock>`, we get persistent file capture (including shutdown) and interactive socket attachment as independent channels.

The kernel cmdline uses `console=ttyS0 console=hvc0` ordering so hvc0 is the last (primary) console — Linux makes it `/dev/console`, meaning all systemd service output goes to the file. Both devices receive kernel printk messages. ttyS0 still runs a serial getty for interactive use via `epi console`.

**Alternative considered**: Multiplexer binary that owns the serial socket and tees to file + client connections. More complex, requires a new binary and systemd service. Unnecessary given ch's native file support.

**Alternative considered**: `--serial file=` + `--console socket=`. Cloud-hypervisor does not support `socket=` for the console device (`NoSocketOptionSupportForConsoleDevice`).

### Fix shutdown script shebang with absolute `sh` path

The shutdown script already resolves ch-remote, timeout, and tail to absolute nix store paths. Apply the same pattern to `sh` — resolve it at script generation time and use the absolute path in the shebang (e.g. `#!/nix/store/.../bin/sh`).

### Stop VM service before slice

`stop_instance` currently calls `process::stop_unit(&slice)` which kills all cgroup processes immediately, bypassing ExecStop. Changed to stop the VM service first (triggering ExecStop → ACPI power-button → guest shutdown), then stop the slice for helper cleanup.

### Make shutdown-vmm non-fatal

When ACPI shutdown succeeds, the VM exits before `shutdown-vmm` runs, causing it to return non-zero. Adding `|| true` prevents a spurious service failure status.

## Risks / Trade-offs

- **ttyS0 loses systemd output**: With `console=ttyS0 console=hvc0`, hvc0 is `/dev/console` and gets all systemd output. Interactive users on ttyS0 only see kernel printk and the serial getty login prompt, not systemd boot progress. → Acceptable: the file captures everything, and `epi console` will show scrollback from console.log on attach.

- **virtio_console module**: The guest kernel needs the virtio_console module. It autoloaded in testing but should be added to `boot.initrd.availableKernelModules` for reliability.

- **Console log file growth**: The file is written for the entire VM lifetime with no rotation. → Acceptable for ephemeral dev VMs. The file is cleaned up on `epi rm`.
