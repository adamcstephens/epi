## Purpose
Define detached VM runtime behavior and serial console attachment workflows for running instances.

## Requirements

### Requirement: Up starts VM runtime in detached mode
The `epi up` command SHALL launch cloud-hypervisor so that VM runtime continues in the background after `up` exits successfully.

#### Scenario: Up returns while VM remains running
- **WHEN** a user runs `epi up dev-a --target .#dev-a` and launch succeeds
- **THEN** the command exits zero without waiting for VM shutdown
- **AND** the VM runtime remains active in the background

### Requirement: Up provisions a serial console attach endpoint
When `up` successfully starts a VM, the CLI MUST provision and store a stable serial console endpoint for that instance.

#### Scenario: Serial endpoint metadata is recorded
- **WHEN** `epi up qa-1 --target .#qa` succeeds
- **THEN** the CLI records serial console endpoint metadata for `qa-1`
- **AND** the endpoint can be used by later CLI commands to attach to the running VM

### Requirement: CLI provides explicit serial console attachment
The CLI SHALL provide `epi console [INSTANCE]` to attach interactively to the running instance serial console by connecting to the serial Unix socket, defaulting to `default` when omitted.

#### Scenario: Attach to explicit instance
- **WHEN** a user runs `epi console dev-a` and `dev-a` is running with a valid serial endpoint
- **THEN** the CLI validates `dev-a` is running
- **AND** the CLI validates the serial socket path exists
- **AND** the CLI establishes a socket connection and relays console I/O

#### Scenario: Attach to implicit default instance
- **WHEN** a user runs `epi console` and `default` is running with a valid serial endpoint
- **THEN** the CLI validates `default` is running
- **AND** the CLI validates the serial socket path exists
- **AND** the CLI establishes a socket connection and relays console I/O

### Requirement: Up supports immediate console attachment workflow
The `epi up` command SHALL support a `--console` flag that provisions the VM and immediately attaches to its serial console.

#### Scenario: Up provisions and attaches console
- **WHEN** `epi up qa-1 --target .#qa --console` succeeds
- **THEN** the CLI provisions and starts the VM in the background
- **AND** the CLI immediately attaches to the serial socket relay path

#### Scenario: Up with console on already running instance
- **WHEN** a user runs `epi up dev-a --target .#dev-a --console` and `dev-a` is already running
- **THEN** the CLI skips VM provisioning
- **AND** the CLI immediately attaches to the existing serial console socket

### Requirement: Console attach failures are actionable
If console attachment cannot proceed, the CLI MUST fail with instance-specific guidance.

#### Scenario: Instance is not running
- **WHEN** a user runs `epi console dev-a` and `dev-a` has no running VM runtime
- **THEN** the command exits non-zero
- **AND** the error states that `dev-a` is not running
- **AND** the error suggests running `epi up dev-a --target <flake#config>`

#### Scenario: Serial endpoint is unavailable
- **WHEN** a user runs `epi console dev-a` and runtime metadata exists but the serial endpoint cannot be opened
- **THEN** the command exits non-zero
- **AND** the error identifies the unavailable serial endpoint path
- **AND** the error suggests checking VM runtime state for `dev-a`
