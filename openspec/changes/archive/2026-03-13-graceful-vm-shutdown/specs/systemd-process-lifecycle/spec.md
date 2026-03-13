## MODIFIED Requirements

### Requirement: VM exit cascades to all helper processes via ExecStopPost
The VM transient service SHALL be configured with `ExecStopPost=` that stops each helper unit individually. When cloud-hypervisor exits for any reason (crash, guest-initiated shutdown, or explicit stop), systemd SHALL automatically stop all helper processes. The `ExecStopPost` command SHALL use the NixOS absolute path `/run/current-system/sw/bin/systemctl` since `ExecStopPost=` does not inherit the user's `$PATH`.

#### Scenario: Guest shutdown cascades to helpers
- **WHEN** a user runs `shutdown` inside the guest VM
- **THEN** cloud-hypervisor exits
- **AND** systemd runs the `ExecStopPost` commands on the VM service
- **AND** each helper unit (passt, virtiofsd) is stopped individually

#### Scenario: VM crash cascades to helpers
- **WHEN** cloud-hypervisor crashes unexpectedly
- **THEN** systemd runs the `ExecStopPost` commands on the VM service
- **AND** each helper unit (passt, virtiofsd) is stopped individually

#### Scenario: Explicit stop cascades to helpers
- **WHEN** a user runs `epi stop dev-a`
- **THEN** the CLI stops the instance slice
- **AND** systemd stops the VM service first (due to ordering)
- **AND** systemd stops helper services after the VM exits
