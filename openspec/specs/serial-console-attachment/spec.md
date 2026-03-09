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

### Requirement: Console relay uses raw terminal mode
When stdin is a TTY, the CLI SHALL set the terminal to raw mode before relaying input, and restore the original terminal settings on exit (including on error or detach).

Raw mode settings applied:
- Echo disabled (`c_echo = false`)
- Canonical mode disabled (`c_icanon = false`) — input forwarded character-by-character
- Signal processing disabled (`c_isig = false`) — Ctrl-C/Ctrl-Z passed to the VM
- Software flow control disabled (`c_ixon = false`)

When stdin is not a TTY (piped or redirected), raw mode is not applied and the relay operates in non-interactive mode.

#### Scenario: Terminal is restored on detach
- **WHEN** a user detaches with Ctrl-T Q
- **THEN** the terminal is restored to its original settings before epi exits
- **AND** the shell prompt behaves normally after epi returns

### Requirement: Escape sequence detaches the console
The detach escape sequence is **Ctrl-T** (`\x14`) followed by **q** or **Q**. All other input is forwarded to the serial socket verbatim.

If Ctrl-T is the last byte in a read buffer (split across two reads), the prefix state is carried forward. If the byte following Ctrl-T is not `q`/`Q`, the Ctrl-T byte is forwarded to the VM and the following byte is processed normally.

A banner is printed to stdout when console attaches:
```
[console attached — ctrl-t q to detach]
```

And when detached:
```
[console detached]
```

#### Scenario: Ctrl-T Q detaches the console
- **WHEN** the user presses Ctrl-T then Q while the console is attached
- **THEN** the CLI closes the socket connection
- **AND** prints `[console detached]`
- **AND** exits zero

### Requirement: Connection retry parameters
The CLI SHALL retry socket connection up to **40 times** with a **50ms** delay between attempts (2-second total window). On `ENOENT` or `ECONNREFUSED`, the retry continues. Any other socket error is a hard failure.

#### Scenario: Socket connects after retries
- **WHEN** the serial socket does not exist at first connection attempt
- **THEN** the CLI retries up to 40 times
- **AND** connects once the socket appears

#### Scenario: Socket connection fails after all retries
- **WHEN** the serial socket is still unavailable after 40 retries
- **THEN** the command exits non-zero
- **AND** the error states the serial endpoint is unavailable

### Requirement: Console supports capture and timeout via environment variables
Non-interactive console workflows (e.g. CI, testing) are controlled via environment variables:

| Variable | Effect |
|----------|--------|
| `EPI_CONSOLE_NON_INTERACTIVE` | `true`/`1`/`yes`/`on` disables stdin reading; `false`/`0`/`no`/`off` forces interactive. Defaults to TTY detection. |
| `EPI_CONSOLE_CAPTURE_FILE` | If set, console output is written to this file path instead of stdout. The file is created (or truncated) at attach time. |
| `EPI_CONSOLE_TIMEOUT_SECONDS` | If set to a positive number, the console session exits after this many seconds of inactivity (no bytes received from the VM). Exits non-zero with a timeout error. |

#### Scenario: Capture file receives console output
- **WHEN** `EPI_CONSOLE_CAPTURE_FILE=/tmp/boot.log` is set
- **THEN** all bytes received from the serial socket are written to `/tmp/boot.log`
- **AND** the captured bytes are not printed to stdout

#### Scenario: Timeout exits non-zero
- **WHEN** `EPI_CONSOLE_TIMEOUT_SECONDS=30` is set and no bytes arrive from the VM for 30 seconds
- **THEN** the command exits non-zero
- **AND** the error states that the console session timed out after 30 seconds
