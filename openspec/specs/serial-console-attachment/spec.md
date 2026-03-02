## Purpose
Define direct serial socket console attachment behavior for interactive VM access.

## Requirements

### Requirement: Console command relays directly to serial socket
The `epi console` command SHALL connect directly to the instance serial Unix socket and relay interactive stdin/stdout without requiring external console tools.

#### Scenario: Console attaches to serial socket
- **WHEN** a user runs `epi console dev-a` and `dev-a` is running
- **THEN** the CLI validates `dev-a` is running with a valid serial socket
- **AND** the CLI connects to the serial socket
- **AND** user input is forwarded to the VM serial console output

#### Scenario: Console validates serial socket exists
- **WHEN** a user runs `epi console dev-a` and the serial socket file does not exist
- **THEN** the command exits non-zero
- **AND** the error states the serial socket is unavailable

### Requirement: Up command supports immediate console attachment
The `epi up` command SHALL accept a `--console` flag that immediately attaches to the serial console after successful VM creation.

#### Scenario: Up with console attaches immediately
- **WHEN** a user runs `epi up dev-a --target .#dev-a --console`
- **THEN** the VM is provisioned and started in the background
- **AND** the CLI immediately connects to the provisioned serial socket
- **AND** the user interacts directly with the VM boot process

#### Scenario: Up with console fails if VM provisioning fails
- **WHEN** a user runs `epi up dev-a --target .#dev-a --console` and provisioning fails
- **THEN** the command exits non-zero with provisioning error
- **AND** no console attachment is attempted

### Requirement: Console flag requires running instance
When using `--console` flag, the CLI MUST verify the VM is actually running before attempting attachment.

#### Scenario: Console flag with zombie process
- **WHEN** a user runs `epi up dev-a --target .#dev-a --console` and the VM process exits immediately
- **THEN** provisioning is marked as failed
- **AND** the command exits non-zero without attempting console attachment

### Requirement: Console attachment tolerates startup race
Console attachment SHALL tolerate short delays between runtime launch and serial socket readiness.

#### Scenario: Socket is not immediately ready
- **WHEN** a user runs `epi up dev-a --target .#dev-a --console` and the serial socket appears shortly after process launch
- **THEN** the CLI retries connection for a bounded interval
- **AND** the CLI attaches successfully once the socket is accepting connections
