## ADDED Requirements

### Requirement: Step-based progress output for long-running operations
The UI module SHALL provide a step-based progress indicator that shows a spinner animation on stderr while an operation is in progress, replaces it with a ✓ prefix on success, and replaces it with a ✗ prefix on failure. The spinner SHALL display elapsed time while active. The step indicator SHALL only animate when stderr is a TTY; when not a TTY, it SHALL print plain text without ANSI codes or cursor manipulation.

#### Scenario: Spinner shown during provisioning
- **WHEN** a user runs `epi launch` in an interactive terminal
- **THEN** stderr shows an animated spinner with the message "Provisioning VM..."
- **AND** elapsed time is displayed alongside the spinner

#### Scenario: Spinner replaced on success
- **WHEN** provisioning completes successfully
- **THEN** the spinner line is replaced with "✓ Provisioned VM" in green

#### Scenario: Spinner replaced on failure
- **WHEN** provisioning fails
- **THEN** the spinner line is replaced with "✗ Provisioning failed" in red

#### Scenario: Plain text when not a TTY
- **WHEN** stderr is piped (not a TTY)
- **THEN** step messages are printed as plain text without ANSI escape codes or spinner animation

### Requirement: Styled informational output
The UI module SHALL provide functions for printing informational, warning, and error messages to stderr with consistent styling. Informational messages SHALL be unstyled. Warning messages SHALL be prefixed with "warning:" in yellow. Error messages SHALL be prefixed with "✗ error:" in red and bold, with additional error chain details indented below.

#### Scenario: Warning message is styled
- **WHEN** a warning is emitted (e.g., non-executable hook file)
- **THEN** stderr shows "warning: hook path/to/file is not executable, skipping" with "warning:" in yellow

#### Scenario: Error message shows chain
- **WHEN** an error occurs with context chain (e.g., "VM failed to boot: exited immediately")
- **THEN** stderr shows "✗ error: VM failed to boot" in red+bold
- **AND** the next line shows "  exited immediately" indented

#### Scenario: Styling disabled with NO_COLOR
- **WHEN** the `NO_COLOR` environment variable is set
- **THEN** all output is plain text without ANSI color codes

### Requirement: Colored state indicators in output
The UI module SHALL use colored dot indicators for instance state: green `●` for running, dim `○` for stopped. These indicators SHALL appear in both status and list command output.

#### Scenario: Running instance shows green dot
- **WHEN** an instance status is "running"
- **THEN** the status is displayed as "● running" with the dot in green

#### Scenario: Stopped instance shows dim dot
- **WHEN** an instance status is "stopped"
- **THEN** the status is displayed as "○ stopped" with the dot dimmed

### Requirement: List output uses dash for empty values
The list command output SHALL display `—` (em dash) for values that are not available (e.g., SSH port when instance is stopped) instead of leaving the cell blank.

#### Scenario: Stopped instance shows dash for SSH
- **WHEN** a stopped instance has no SSH port
- **THEN** the SSH column shows `—` instead of empty space
