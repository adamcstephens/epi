## ADDED Requirements

### Requirement: Cloud-hypervisor writes console output to file via virtio-console
The VM SHALL be launched with `--console file=<console_log_path>` so that cloud-hypervisor writes all virtio-console (hvc0) output directly to a file for the full VM lifecycle.

#### Scenario: Console log captures boot and shutdown output
- **WHEN** a VM is launched and subsequently stopped via `epi stop`
- **THEN** the console log file contains boot output (systemd service startup messages)
- **AND** the console log file contains shutdown output (systemd service stop messages, "System Power Off")

#### Scenario: Console log file is written to the instance directory
- **WHEN** `epi launch dev-a --target .#dev-a` provisions successfully
- **THEN** the console log file is created at `<instance_dir>/console.log`
- **AND** the file is written by cloud-hypervisor, not by the epi process

### Requirement: Kernel cmdline includes hvc0 console
The kernel cmdline SHALL include `console=hvc0` as the last console parameter to make it the primary `/dev/console`. The ordering SHALL be `console=ttyS0 console=hvc0` so that hvc0 receives all systemd output for file capture. ttyS0 still receives kernel printk and runs a serial getty for interactive use.

#### Scenario: Both console devices receive output
- **WHEN** a VM boots with cmdline containing `console=hvc0 console=ttyS0`
- **THEN** the virtio-console file captures kernel and systemd boot messages
- **AND** the serial socket also receives kernel and systemd boot messages

### Requirement: Guest kernel loads virtio_console module
The NixOS guest configuration SHALL include `virtio_console` in `boot.initrd.availableKernelModules` to ensure the hvc0 device is available early in boot.

#### Scenario: hvc0 device exists in guest
- **WHEN** a VM boots with the epi NixOS configuration
- **THEN** the `/dev/hvc0` device exists in the guest
