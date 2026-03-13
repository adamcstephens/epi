## MODIFIED Requirements

### Requirement: VM service ExecStop performs graceful shutdown via ch-remote
The CLI SHALL generate a shutdown script at `<instance-dir>/shutdown.sh` during launch. The script SHALL contain the graceful shutdown sequence with absolute paths to all binaries resolved at launch time. The VM transient service SHALL be configured with a single `ExecStop=<instance-dir>/shutdown.sh` that executes this script.

The shutdown script SHALL perform the following sequence:
1. `<abs-path>/ch-remote --api-socket <instance-dir>/api.sock power-button` — sends ACPI power button to the guest
2. `<abs-path>/timeout 15 <abs-path>/tail --pid=$MAINPID -f /dev/null` — waits up to 15 seconds for cloud-hypervisor to exit
3. `<abs-path>/ch-remote --api-socket <instance-dir>/api.sock shutdown-vmm` — forcefully exits the VMM process

The CLI SHALL resolve absolute paths for `ch-remote`, `timeout`, and `tail` at launch time. If any binary cannot be found in PATH, the launch SHALL fail with an error.

#### Scenario: Guest shuts down cleanly within timeout
- **WHEN** `epi stop dev-a` is run and the guest OS responds to the ACPI power button
- **THEN** the shutdown script sends the power-button command
- **AND** cloud-hypervisor exits when the guest completes shutdown
- **AND** the wait command returns early because the main process exited
- **AND** the shutdown-vmm command fails harmlessly (process already gone)

#### Scenario: Guest does not respond to power button within 15 seconds
- **WHEN** `epi stop dev-a` is run and the guest OS does not respond to the ACPI power button
- **THEN** the shutdown script sends the power-button command
- **AND** the wait command times out after 15 seconds
- **AND** the shutdown-vmm command forcefully exits cloud-hypervisor

#### Scenario: API socket is not available
- **WHEN** `epi stop dev-a` is run and the API socket is not reachable
- **THEN** the ch-remote commands in the script fail
- **AND** the script continues regardless
- **AND** systemd falls back to TimeoutStopSec SIGKILL

#### Scenario: Required binary not found at launch
- **WHEN** `epi launch dev-a` is run and `ch-remote` is not in PATH
- **THEN** the launch fails with an error indicating the missing binary
- **AND** no VM is started
