## MODIFIED Requirements

### Requirement: Console command relays directly to serial socket
The `epi console` command SHALL connect directly to the instance serial Unix socket and relay interactive stdin/stdout without requiring external console tools. Before connecting to the serial socket, the CLI SHALL dump recent scrollback from `console.log` if available.

#### Scenario: Console attaches to serial socket
- **WHEN** a user runs `epi console dev-a` and `dev-a` is running
- **THEN** the CLI validates `dev-a` is running with a valid serial socket
- **AND** the CLI prints scrollback from `console.log` (if available)
- **AND** the CLI connects to the serial socket
- **AND** user input is forwarded to the VM serial console output
