## ADDED Requirements

### Requirement: VM service starts after helper services
The VM transient service SHALL be configured with `After=<helper>.service` for each helper unit (passt, virtiofsd). This ensures systemd starts helpers before the VM and stops the VM before helpers when the slice is stopped.

#### Scenario: VM starts after passt and virtiofsd
- **WHEN** `epi launch dev-a --target .#dev-a --mount /home/user/src` provisions successfully
- **THEN** the VM service has `After=epi-<escaped>_<id>_passt.service`
- **AND** the VM service has `After=epi-<escaped>_<id>_virtiofsd0.service`

#### Scenario: Slice stop respects ordering
- **WHEN** `epi stop dev-a` stops the instance slice
- **THEN** systemd stops the VM service first (ExecStop graceful shutdown sequence)
- **AND** systemd stops helper services after the VM service has exited
- **AND** helper sockets remain alive during VM shutdown
