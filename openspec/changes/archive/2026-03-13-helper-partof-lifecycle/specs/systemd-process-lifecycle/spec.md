## MODIFIED Requirements

### Requirement: VM exit cascades to all helper processes via ExecStopPost
Each helper transient service (passt, virtiofsd) SHALL be configured with `PartOf=<vm-unit>.service` so that systemd automatically stops helpers when the VM unit stops. The VM service SHALL NOT use `ExecStopPost` for helper cleanup.

#### Scenario: Guest shutdown cascades to helpers
- **WHEN** a user runs `shutdown` inside the guest VM
- **THEN** cloud-hypervisor exits
- **AND** systemd stops each helper unit via the `PartOf=` directive
- **AND** each helper unit (passt, virtiofsd) is stopped

#### Scenario: VM crash cascades to helpers
- **WHEN** cloud-hypervisor crashes unexpectedly
- **THEN** systemd stops each helper unit via the `PartOf=` directive
- **AND** each helper unit (passt, virtiofsd) is stopped

#### Scenario: Explicit stop cascades to helpers
- **WHEN** a user runs `epi stop dev-a`
- **THEN** the CLI stops the instance slice
- **AND** systemd stops the VM service first (due to ordering)
- **AND** systemd stops helper services after the VM exits
