## MODIFIED Requirements

### Requirement: VM service starts after helper services
The VM transient service SHALL be configured with `After=<helper>.service` for each helper unit (passt, virtiofsd). This ensures systemd starts helpers before the VM and stops the VM before helpers when the slice is stopped.

#### Scenario: VM starts after passt and virtiofsd
- **WHEN** `epi launch dev-a --target .#dev-a --mount /home/user/src` provisions successfully
- **THEN** the VM service has `After=epi-<escaped>_<id>_passt.service`
- **AND** the VM service has `After=epi-<escaped>_<id>_virtiofsd0.service`

#### Scenario: Stop triggers graceful shutdown before killing helpers
- **WHEN** `epi stop dev-a` stops the instance
- **THEN** the CLI stops the VM service first, triggering ExecStop (ACPI power-button → guest shutdown)
- **AND** the CLI stops the slice after the VM service has exited, cleaning up helper services
- **AND** helper sockets remain alive during VM shutdown

## ADDED Requirements

### Requirement: Shutdown script uses absolute interpreter path
The ExecStop shutdown script SHALL use an absolute path to `sh` in the shebang (e.g. `#!/nix/store/.../bin/sh`), resolved at script generation time. This ensures the script executes correctly in systemd's minimal environment where `/usr/bin/env sh` may not resolve.

#### Scenario: Shutdown script executes in systemd context
- **WHEN** `systemctl --user stop` triggers ExecStop on the VM service
- **THEN** the shutdown script executes successfully
- **AND** the script sends ACPI power-button to the guest

### Requirement: Shutdown force-kill is non-fatal
The `shutdown-vmm` fallback command in the ExecStop script SHALL be non-fatal (`|| true`). When the guest shuts down cleanly via ACPI, the VM process exits before `shutdown-vmm` runs, causing it to return non-zero. This MUST NOT cause the service to report failure.

#### Scenario: Clean ACPI shutdown does not report failure
- **WHEN** the guest handles ACPI power-button and exits before the force-kill timeout
- **THEN** the `shutdown-vmm` command fails silently
- **AND** the service reports successful stop
