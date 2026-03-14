## MODIFIED Requirements

### Requirement: Launch provisions a serial console attach endpoint
When `launch` successfully starts a VM, the CLI MUST provision and store a stable serial console endpoint for that instance. Console output capture is handled natively by cloud-hypervisor via the virtio-console device (`--console file=`), not by the CLI process. The CLI SHALL NOT run a background capture thread.

#### Scenario: Serial endpoint metadata is recorded
- **WHEN** `epi launch qa-1 --target .#qa` succeeds
- **THEN** the CLI records serial console endpoint metadata for `qa-1`
- **AND** the endpoint can be used by later CLI commands to attach to the running VM

#### Scenario: Console log is written by cloud-hypervisor
- **WHEN** `epi launch qa-1 --target .#qa` succeeds
- **THEN** cloud-hypervisor writes console output to a file in the instance directory
- **AND** the CLI does not spawn a background thread to capture serial output
