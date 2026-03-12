## MODIFIED Requirements

### Requirement: In-process integration tests exercise provisioning without CLI subprocess
Integration tests that verify the full provisioning flow SHALL call `Vm_launch.provision` directly with mock first-class modules for target resolution and VM orchestration. Tests SHALL NOT require mock shell scripts or env-var-based binary swapping for the provision flow.

#### Scenario: Provision flow tested in-process
- **WHEN** an in-process integration test constructs a mock `Target_resolver` returning a known descriptor
- **AND** constructs a mock `Vm_runner` returning a known runtime
- **AND** calls `Vm_launch.provision` with these mocks
- **THEN** the function returns `Ok runtime`
- **AND** the test asserts on the return value and any files written to the state directory
- **AND** no external processes are spawned

#### Scenario: Failed provision tested without mock binaries
- **WHEN** an in-process integration test constructs a mock `Vm_runner` that returns an error
- **AND** calls `Vm_launch.provision`
- **THEN** the function returns the expected `Error` variant
- **AND** no runtime state is persisted
- **AND** no external processes are spawned

#### Scenario: Cached descriptor reuse tested without mock binaries
- **WHEN** an in-process integration test constructs a mock `Target_resolver` that counts calls
- **AND** calls `Vm_launch.provision` twice with the same target
- **THEN** the resolver is called once (second call uses cache)
- **AND** no external processes are spawned

### Requirement: Mock shell scripts removed from provision integration tests
The shell-script mock infrastructure in `mock_runtime.ml` and `test_provision_integration.ml` (resolver.sh, cloud-hypervisor.sh, xorriso.sh, passt.sh, systemd-run.sh, systemctl.sh, virtiofsd.sh) SHALL be removed once all provision integration tests are converted to use module-level mocks. Shell mocks MAY be retained temporarily for CLI integration tests that still spawn the epi binary.

#### Scenario: No shell mocks needed for provision tests
- **WHEN** all provision integration tests use module-level mocks
- **THEN** no test writes shell scripts to temp directories for the purpose of mocking process behavior in provision tests
