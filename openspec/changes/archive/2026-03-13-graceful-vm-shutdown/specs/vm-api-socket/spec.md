## ADDED Requirements

### Requirement: CLI launches cloud-hypervisor with an API socket
The CLI SHALL pass `--api-socket path=<instance-dir>/api.sock` to cloud-hypervisor at launch. The CLI SHALL remove any stale `api.sock` file before launching.

#### Scenario: API socket is created at launch
- **WHEN** `epi launch dev-a --target .#dev-a` provisions successfully
- **THEN** cloud-hypervisor is started with `--api-socket path=<instance-dir>/api.sock`
- **AND** the API socket file exists in the instance directory

#### Scenario: Stale API socket is cleaned before launch
- **WHEN** `epi launch dev-a --target .#dev-a` is run and `api.sock` exists from a previous launch
- **THEN** the CLI removes the stale `api.sock` before starting cloud-hypervisor

### Requirement: VM service ExecStop performs graceful shutdown via ch-remote
The VM transient service SHALL be configured with three `ExecStop` commands that execute in sequence:
1. `ch-remote --api-socket <instance-dir>/api.sock power-button` — sends ACPI power button to the guest
2. `timeout 15 tail --pid=$MAINPID -f /dev/null` — waits up to 15 seconds for cloud-hypervisor to exit
3. `ch-remote --api-socket <instance-dir>/api.sock shutdown-vmm` — forcefully exits the VMM process

#### Scenario: Guest shuts down cleanly within timeout
- **WHEN** `epi stop dev-a` is run and the guest OS responds to the ACPI power button
- **THEN** ExecStop sends the power-button command
- **AND** cloud-hypervisor exits when the guest completes shutdown
- **AND** the wait command returns early because the main process exited
- **AND** the shutdown-vmm command fails harmlessly (process already gone)

#### Scenario: Guest does not respond to power button within 15 seconds
- **WHEN** `epi stop dev-a` is run and the guest OS does not respond to the ACPI power button
- **THEN** ExecStop sends the power-button command
- **AND** the wait command times out after 15 seconds
- **AND** the shutdown-vmm command forcefully exits cloud-hypervisor

#### Scenario: API socket is not available
- **WHEN** `epi stop dev-a` is run and the API socket is not reachable
- **THEN** the ch-remote commands fail
- **AND** ExecStop commands continue regardless
- **AND** systemd falls back to TimeoutStopSec SIGKILL

### Requirement: VM service has a TimeoutStopSec safety net
The VM transient service SHALL be configured with `TimeoutStopSec=20`. If the ExecStop sequence and SIGTERM do not terminate cloud-hypervisor within 20 seconds, systemd SHALL send SIGKILL.

#### Scenario: All shutdown methods fail
- **WHEN** the ExecStop sequence fails and cloud-hypervisor ignores SIGTERM
- **THEN** systemd sends SIGKILL after 20 seconds
- **AND** the process is forcefully terminated
