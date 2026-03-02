## ADDED Requirements

### Requirement: Remove a stopped VM
The CLI SHALL delete a VM that is already stopped when `vm rm <id>` is invoked without additional flags.

#### Scenario: Remove stopped VM
- **WHEN** the operator runs `vm rm vm-123` while `vm-123` reports the `Stopped` lifecycle state
- **THEN** the system deletes `vm-123`, reports success, and exits with a zero status

### Requirement: Force remove a running VM
The CLI SHALL allow forcing deletion of a running VM when the `-f/--force` flag is supplied. The command MUST issue the same termination request that regular stop flows use before performing deletion.

#### Scenario: Force remove running VM
- **WHEN** the operator runs `vm rm -f vm-123` and `vm-123` reports the `Running` state
- **THEN** the system issues the termination request, waits for termination confirmation, deletes `vm-123`, and exits with success

### Requirement: Reject running VM without force
The CLI SHALL refuse to delete a running VM when `-f/--force` is not provided, explaining that the VM must be stopped first.

#### Scenario: Reject running VM without force
- **WHEN** the operator runs `vm rm vm-123` while `vm-123` is `Running`
- **THEN** the system refuses to delete the VM, outputs a message instructing the operator to stop it first, and exits with a non-zero status

### Requirement: Surface termination failure
If forcing deletion fails because the termination request cannot complete, the CLI SHALL stop before deleting and return an error describing the failure, keeping the VM intact.

#### Scenario: Force delete fails due to termination error
- **WHEN** the operator runs `vm rm -f vm-123` but the termination API returns an error
- **THEN** the CLI reports a failure referencing the termination error, leaves `vm-123` untouched, and exits with a non-zero status
