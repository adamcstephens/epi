## ADDED Requirements

### Requirement: Unit tests call library functions directly with isolated state
Unit tests SHALL call `vm_launch`, `target`, `instance_store`, and related module functions directly in-process. Each test SHALL use an isolated temporary directory for state and file I/O. Tests SHALL NOT spawn the `epi` binary as a subprocess.

#### Scenario: epi.json generation tested in-process
- **WHEN** a unit test calls `vm_launch::generate_epi_json` with instance_name, username, SSH keys, user_exists, host_uid, and mount_paths
- **THEN** the function returns a JSON string
- **AND** the test asserts on the parsed JSON content directly without parsing CLI stdout

#### Scenario: Cache tested in-process
- **WHEN** a unit test calls `target::resolve_descriptor_cached` with a temp cache dir and mock resolver
- **THEN** the function returns a `cache_result` value
- **AND** the test asserts on the variant (`Cached` vs `Resolved`) and descriptor fields

#### Scenario: State isolation between tests
- **WHEN** two tests run sequentially
- **THEN** each test operates on its own temporary directory
- **AND** no state leaks between tests

### Requirement: Mock shell scripts removed from provision integration tests
The shell-script mock infrastructure in `mock_runtime.rs` and `test_provision_integration.rs` (resolver.sh, cloud-hypervisor.sh, xorriso.sh, passt.sh, systemd-run.sh, systemctl.sh, virtiofsd.sh) SHALL be removed once all provision integration tests are converted to use module-level mocks. Shell mocks MAY be retained temporarily for CLI integration tests that still spawn the epi binary.

#### Scenario: No shell mocks needed for provision tests
- **WHEN** all provision integration tests use module-level mocks
- **THEN** no test writes shell scripts to temp directories for the purpose of mocking process behavior in provision tests

### Requirement: Tests are split into separate test targets for concurrency
Tests SHALL be organized into separate test targets that cargo/just can run concurrently:

#### Scenario: Unit tests run independently
- **WHEN** `just test-unit` is run
- **THEN** all unit tests execute in-process without requiring the epi binary or external dependencies

#### Scenario: CLI smoke tests run independently
- **WHEN** `just test-cli` is run
- **THEN** CLI smoke tests and mock-based integration tests execute
- **AND** no e2e tests requiring real VMs are included

#### Scenario: E2e tests run independently
- **WHEN** `just test-e2e` is run
- **THEN** only real-VM e2e tests execute (e2e-lifecycle, e2e-mount, e2e-setup)

### Requirement: CLI smoke tests verify argument parsing and command routing
A minimal set of CLI tests SHALL spawn the `epi` binary to verify that argument parsing, help output, and basic command routing work correctly. These tests SHALL NOT cover business logic already tested at the unit level.

#### Scenario: Help output is correct
- **WHEN** a CLI smoke test runs `epi launch --help=plain`
- **THEN** the output includes expected flags (`--target`, `--rebuild`, `--mount`, `--no-provision`)

#### Scenario: Missing required arguments produce errors
- **WHEN** a CLI smoke test runs `epi launch` without a `--target` flag and no existing instance
- **THEN** the command exits non-zero with a usage error
