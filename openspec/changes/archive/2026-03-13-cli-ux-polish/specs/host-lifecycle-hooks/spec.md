## MODIFIED Requirements

### Requirement: Host hooks are executed with instance environment variables
The system SHALL execute each collected hook script sequentially as a subprocess. The following environment variables SHALL be set: `EPI_INSTANCE` (instance name), `EPI_SSH_PORT` (SSH port number), `EPI_SSH_KEY` (path to SSH private key), `EPI_SSH_USER` (SSH username), `EPI_STATE_DIR` (instance state directory path), `EPI_BIN` (absolute path to the epi binary). Each hook script SHALL be displayed as a step with a spinner while executing. On success, the step SHALL show "✓ hook: <script-name>". On failure, the step SHALL show "✗ hook: <script-name>" and the system SHALL stop executing remaining hooks and report the failure.

#### Scenario: Hook receives environment variables
- **WHEN** a post-launch hook script runs for instance `dev` on SSH port 12345
- **THEN** the script's environment contains `EPI_INSTANCE=dev` and `EPI_SSH_PORT=12345`

#### Scenario: Hook shows step progress
- **WHEN** a hook script `setup.sh` is executed
- **THEN** stderr shows a spinner with "Running hook: setup.sh" while it executes
- **AND** on success, the spinner is replaced with "✓ hook: setup.sh"

#### Scenario: Hook failure shows failure indicator
- **WHEN** a hook script `setup.sh` exits with code 1
- **THEN** stderr shows "✗ hook: setup.sh"
- **AND** subsequent hook scripts are NOT executed
- **AND** the system reports the hook failure

#### Scenario: Non-executable scripts are skipped with warning
- **WHEN** a file exists in the hook directory but is not executable
- **THEN** the file is skipped
- **AND** a styled warning is printed to stderr
