## Purpose
Define console scrollback behavior when attaching to a VM's serial console.

## Requirements

### Requirement: Console attach dumps scrollback from console.log
When `epi console` attaches to a running instance, the CLI SHALL read the tail of the instance's `console.log` file and print it to stdout before connecting to the live serial socket. If `console.log` does not exist or is empty, scrollback is silently skipped.

#### Scenario: Scrollback shows recent boot output
- **WHEN** a user runs `epi console dev-a` and `dev-a` has been running with console output in `console.log`
- **THEN** the CLI prints the last 8KB of `console.log` content to stdout
- **AND** the CLI then connects to the serial socket for live interaction

#### Scenario: Scrollback is skipped when console.log is missing
- **WHEN** a user runs `epi console dev-a` and no `console.log` exists for `dev-a`
- **THEN** the CLI skips scrollback without error
- **AND** the CLI connects to the serial socket normally

### Requirement: Scrollback is limited to prevent terminal flooding
The scrollback dump SHALL read at most 8192 bytes from the end of `console.log`. If the file is smaller than this limit, the entire file is printed.

#### Scenario: Large console.log is truncated
- **WHEN** `console.log` is 50KB and `epi console` attaches
- **THEN** only the last 8192 bytes are printed as scrollback

### Requirement: Scrollback strips control characters
The scrollback dump SHALL strip ANSI escape sequences, OSC sequences, and non-printable control characters (0x00-0x1F) except newline (0x0A) and carriage return (0x0D). This ensures the scrollback output does not corrupt the user's terminal.

#### Scenario: ANSI color codes are removed
- **WHEN** `console.log` contains `\x1b[32mOK\x1b[0m`
- **THEN** the scrollback output contains `OK` without escape sequences

#### Scenario: Systemd status protocol markers are removed
- **WHEN** `console.log` contains OSC sequences from systemd
- **THEN** the scrollback output does not contain those sequences

### Requirement: Scrollback has visual separators
The scrollback dump SHALL be wrapped with a header and footer separator line so the user can distinguish historical output from live serial output.

#### Scenario: Separators are visible
- **WHEN** scrollback is printed
- **THEN** a header line is printed before the scrollback content
- **AND** a footer line is printed after the scrollback content
- **AND** the footer indicates that live output follows
