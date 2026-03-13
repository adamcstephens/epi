## MODIFIED Requirements

### Requirement: CLI starts cloud-hypervisor as a transient systemd service
The CLI SHALL start cloud-hypervisor as a transient systemd user service (`systemd-run --user` without `--scope`) with `Type=exec`. This enables `ExecStopPost=` for cascading shutdown when the VM exits. The CLI SHALL NOT forward the user's environment to the service; the process SHALL run with systemd's default environment only.

#### Scenario: Cloud-hypervisor is started as a transient service
- **WHEN** `epi launch dev-a --target .#dev-a` provisions successfully
- **THEN** the cloud-hypervisor process runs inside a transient systemd user service named `epi-<escaped>-<id>-vm.service`
- **AND** the service is a member of the instance slice

#### Scenario: Cloud-hypervisor runs without user environment
- **WHEN** a sentinel environment variable is set in the CLI process before launch
- **AND** `epi launch dev-a --target .#dev-a` provisions successfully
- **THEN** the VM service unit's `Environment` property does not contain the sentinel variable
- **AND** the process runs with systemd's default minimal environment

### Requirement: CLI starts helper processes as systemd user services
The CLI SHALL start passt and virtiofsd as transient systemd user services (`systemd-run --user` without `--scope`), grouped under the same instance slice as the VM service. Unit names end in `.service`. The CLI SHALL NOT forward the user's environment to helper services; they SHALL run with systemd's default environment only.

#### Scenario: Passt is started as a systemd service
- **WHEN** `epi launch dev-a --target .#dev-a` provisions successfully
- **THEN** the passt process runs inside a systemd user service named `epi-<escaped>-<id>-passt.service`
- **AND** the service is a member of the instance slice

#### Scenario: Virtiofsd instances are started as systemd services
- **WHEN** `epi launch dev-a --target .#dev-a --mount /home/user/src --mount /home/user/data` provisions successfully
- **THEN** each virtiofsd process runs inside a systemd user service named `epi-<escaped>-<id>-virtiofsd-<index>.service`
- **AND** each service is a member of the instance slice

#### Scenario: Helper processes run without user environment
- **WHEN** a sentinel environment variable is set in the CLI process before launch
- **AND** `epi launch dev-a --target .#dev-a` provisions successfully
- **THEN** the passt service unit's `Environment` property does not contain the sentinel variable
- **AND** the processes run with systemd's default minimal environment
