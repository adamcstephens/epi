## MODIFIED Requirements

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

## ADDED Requirements

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
