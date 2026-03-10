## ADDED Requirements

### Requirement: Unit tests call library functions directly with isolated state
Unit tests SHALL call `Vm_launch`, `Target`, `Instance_store`, and related module functions directly in-process. Each test SHALL use an isolated temporary directory for state and file I/O. Tests SHALL NOT spawn the `epi` binary as a subprocess.

#### Scenario: epi.json generation tested in-process
- **WHEN** a unit test calls `Vm_launch.generate_epi_json` with instance_name, username, SSH keys, user_exists, host_uid, and mount_paths
- **THEN** the function returns a JSON string
- **AND** the test asserts on the parsed JSON content directly without parsing CLI stdout

#### Scenario: Cache tested in-process
- **WHEN** a unit test calls `Target.resolve_descriptor_cached` with a temp cache dir and mock resolver
- **THEN** the function returns a `cache_result` value
- **AND** the test asserts on the variant (`Cached` vs `Resolved`) and descriptor fields

#### Scenario: State isolation between tests
- **WHEN** two tests run sequentially
- **THEN** each test operates on its own temporary directory
- **AND** no state leaks between tests

### Requirement: In-process integration tests exercise provisioning without CLI subprocess
Integration tests that verify the full provisioning flow SHALL call `Vm_launch.provision` directly with environment variables pointing to mock binaries. The mock shell scripts from `mock_runtime.ml` SHALL be reused for mock binary behavior.

#### Scenario: Provision flow tested in-process
- **WHEN** an in-process integration test sets `EPI_CLOUD_HYPERVISOR_BIN`, `EPI_TARGET_RESOLVER_CMD`, and other env vars to mock scripts
- **AND** calls `Vm_launch.provision` with an instance name and target
- **THEN** the function returns a `provision_result` or `provision_error`
- **AND** the test asserts on the return value and any files written to the state directory

### Requirement: Tests are split into separate binaries for concurrency
Tests SHALL be organized into three separate binaries that dune can build and run concurrently:

#### Scenario: Unit tests run independently
- **WHEN** `dune exec test/unit/test_unit.exe` is run
- **THEN** all unit tests execute in-process without requiring the epi binary or external dependencies

#### Scenario: CLI smoke tests run independently
- **WHEN** `dune exec test/test_epi.exe -- _build/default/bin/epi.exe` is run
- **THEN** CLI smoke tests and mock-based integration tests execute
- **AND** no e2e tests requiring real VMs are included

#### Scenario: E2e tests run independently
- **WHEN** `dune exec test/e2e/test_e2e.exe -- _build/default/bin/epi.exe -e` is run
- **THEN** only real-VM e2e tests execute (e2e-lifecycle, e2e-mount, e2e-setup)

### Requirement: CLI smoke tests verify argument parsing and command routing
A minimal set of CLI tests SHALL spawn the `epi` binary to verify that argument parsing, help output, and basic command routing work correctly. These tests SHALL NOT cover business logic already tested at the unit level.

#### Scenario: Help output is correct
- **WHEN** a CLI smoke test runs `epi launch --help=plain`
- **THEN** the output includes expected flags (`--target`, `--rebuild`, `--mount`, `--no-wait`)

#### Scenario: Missing required arguments produce errors
- **WHEN** a CLI smoke test runs `epi launch` without a `--target` flag and no existing instance
- **THEN** the command exits non-zero with a usage error
