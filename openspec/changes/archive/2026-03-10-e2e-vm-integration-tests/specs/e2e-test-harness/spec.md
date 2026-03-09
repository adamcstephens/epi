## ADDED Requirements

### Requirement: Unique instance name generation
The test harness SHALL provide a function that generates unique instance names with a given prefix and random suffix to prevent collisions between test runs.

#### Scenario: Generate unique name
- **WHEN** a test calls the unique name generator with prefix "e2e-lifecycle"
- **THEN** the result SHALL be a string like "e2e-lifecycle-a1b2c3" with a random hex suffix

### Requirement: Instance cleanup on test completion
The test harness SHALL provide a wrapper that ensures VM instances are stopped and removed after a test completes, regardless of success or failure. Cleanup SHALL call `Epi.stop_instance` and `Instance_store.remove` directly.

#### Scenario: Cleanup after successful test
- **WHEN** a test wrapped in the cleanup handler completes successfully
- **THEN** the instance SHALL be stopped and its state removed via library calls

#### Scenario: Cleanup after test failure
- **WHEN** a test wrapped in the cleanup handler raises an exception
- **THEN** the instance SHALL still be stopped and its state removed before the exception propagates

### Requirement: VM provision and SSH wait helper
The test harness SHALL provide a helper that provisions a VM via `Vm_launch.provision` and waits for SSH via `Vm_launch.wait_for_ssh`, returning the runtime record on success or failing the test on error.

#### Scenario: Successful provision and SSH wait
- **WHEN** a test calls the provision helper with a valid target and instance name
- **THEN** the helper SHALL return the `Instance_store.runtime` record with SSH port and key path populated

#### Scenario: Provision failure
- **WHEN** provisioning fails (e.g., target resolution error)
- **THEN** the helper SHALL fail the alcotest case with a descriptive error message from `Vm_launch.pp_provision_error`

### Requirement: SSH command execution helper
The test harness SHALL provide a helper that executes a command in the guest VM via SSH using the runtime record's `ssh_port` and `ssh_key_path` fields.

#### Scenario: Execute command in guest
- **WHEN** a test calls the SSH exec helper with a runtime record and command `["echo"; "ok"]`
- **THEN** the helper SHALL SSH into the guest and return the command's stdout

### Requirement: Lifecycle test coverage
The test suite SHALL include a `Slow` alcotest case that exercises the full VM lifecycle: provision, verify SSH connectivity, stop, verify stopped, start, verify SSH again, and remove.

#### Scenario: Full lifecycle
- **WHEN** the lifecycle test runs
- **THEN** it SHALL provision a VM with `.#manual-test`, verify SSH exec works, stop the instance, start it again, verify SSH exec works after restart, then remove the instance and verify it no longer appears in the instance list
