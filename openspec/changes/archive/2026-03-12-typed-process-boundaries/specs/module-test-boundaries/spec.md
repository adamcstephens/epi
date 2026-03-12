## ADDED Requirements

### Requirement: Target_resolver module type defines the resolution boundary
The system SHALL define a `Target_resolver` module type with a `resolve_descriptor` function that takes a target string and returns `(Target.descriptor, Target.resolve_error) result`. The real implementation SHALL delegate to the existing `Target.resolve_descriptor` logic. Test doubles SHALL return pre-configured descriptors or errors without spawning processes.

#### Scenario: Real resolver calls nix eval
- **WHEN** the real `Target_resolver` implementation receives target `".#nixosConfigurations.foo"`
- **THEN** it calls `nix eval` or the configured resolver command
- **AND** returns `Ok descriptor` or `Error resolve_error`

#### Scenario: Mock resolver returns a canned descriptor
- **WHEN** a test provides a mock `Target_resolver` that maps `".#test"` to a known descriptor
- **AND** the provision flow calls `resolve_descriptor ".#test"`
- **THEN** the mock returns `Ok descriptor` without spawning any process

#### Scenario: Mock resolver returns an error
- **WHEN** a test provides a mock `Target_resolver` that returns `Error` for `".#fail"`
- **AND** the provision flow calls `resolve_descriptor ".#fail"`
- **THEN** the flow receives the error and propagates it as a `provision_error`

### Requirement: Vm_runner module type defines the VM orchestration boundary
The system SHALL define a `Vm_runner` module type with functions for launching a VM and waiting for SSH. The real implementation SHALL delegate to the existing `Vm_launch` process-spawning logic. Test doubles SHALL return typed results without spawning processes.

#### Scenario: Real runner launches via systemd-run
- **WHEN** the real `Vm_runner` implementation receives a launch request
- **THEN** it spawns passt, virtiofsd, and cloud-hypervisor via `systemd-run`
- **AND** returns `Ok runtime` with unit_id, ssh_port, and slice name

#### Scenario: Mock runner returns a canned runtime
- **WHEN** a test provides a mock `Vm_runner` that always succeeds
- **AND** the provision flow calls `launch_vm`
- **THEN** the mock returns `Ok runtime` with test values for unit_id and ssh_port

#### Scenario: Mock runner simulates launch failure
- **WHEN** a test provides a mock `Vm_runner` configured to fail
- **AND** the provision flow calls `launch_vm`
- **THEN** the mock returns `Error (Vm_launch_failed ...)` without spawning any process

### Requirement: Provision function accepts dependencies as first-class modules
`Vm_launch.provision` SHALL accept optional `?resolver` and `?runner` parameters as first-class modules. When not provided, the real implementations SHALL be used as defaults. Tests SHALL pass mock implementations to exercise the provision flow without process spawning.

#### Scenario: Default parameters use real implementations
- **WHEN** `Vm_launch.provision` is called without `?resolver` or `?runner`
- **THEN** it uses the real `Target_resolver` and `Vm_runner` implementations
- **AND** behavior is identical to the current implementation

#### Scenario: Test passes mock modules
- **WHEN** a test calls `Vm_launch.provision ~resolver:(module Mock_resolver) ~runner:(module Mock_runner)`
- **THEN** the provision flow uses the mock implementations for resolution and launch
- **AND** no processes are spawned
