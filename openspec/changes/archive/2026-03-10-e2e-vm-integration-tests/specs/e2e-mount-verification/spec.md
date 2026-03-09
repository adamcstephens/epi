## ADDED Requirements

### Requirement: Mount is visible and readable in guest
The test suite SHALL include a `Slow` alcotest case that provisions a VM with a host directory mounted, then verifies the mount contents are accessible inside the guest.

#### Scenario: File created on host is readable in guest
- **WHEN** the test creates a temp directory with a marker file, provisions a VM with that directory as a mount path, and SSHes into the guest to read the file
- **THEN** the marker file SHALL be present at the expected mount path in the guest and its contents SHALL match what was written on the host

### Requirement: Mount persists across stop/start
The test suite SHALL include a `Slow` alcotest case that verifies a mount remains accessible after stopping and restarting the VM.

#### Scenario: Mount accessible after restart
- **WHEN** the test provisions a VM with a mount, stops the instance, starts it again, and reads the mounted file via SSH
- **THEN** the file contents SHALL still be readable and match the original host-side content
