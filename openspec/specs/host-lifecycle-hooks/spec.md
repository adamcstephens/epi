### Requirement: Host hooks are discovered from drop-in directories
The system SHALL discover host hook scripts from drop-in directories at three layers: user-level (`~/.config/epi/hooks/<hook-point>.d/`), project-level (`.epi/hooks/<hook-point>.d/`), and nix-config-level (paths from the target descriptor's `hooks.<hook-point>` array). Within each file-based layer, the system SHALL collect top-level executable files (applying to all instances) and executable files from a subdirectory matching the instance name (applying to that instance only). Dotfiles are ignored. Non-executable files are skipped with a warning. Files SHALL be sorted lexically within each group. Overall execution order SHALL be: user top-level → user `<instance>/` → project top-level → project `<instance>/` → nix-config hooks. Nix-config hooks are already sorted by the NixOS module and do not have instance subdirectories.

#### Scenario: Project-level hook scripts are discovered
- **WHEN** `.epi/hooks/post-launch.d/` contains `00-setup.sh` and `01-check.sh`
- **THEN** both scripts are collected in lexical order: `00-setup.sh`, `01-check.sh`

#### Scenario: Instance-specific hooks are discovered
- **WHEN** `.epi/hooks/post-launch.d/dev/seed-db.sh` exists
- **AND** the instance name is `dev`
- **THEN** `seed-db.sh` is collected for execution

#### Scenario: Instance subdirectory is ignored for other instances
- **WHEN** `.epi/hooks/post-launch.d/dev/seed-db.sh` exists
- **AND** the instance name is `staging`
- **THEN** `seed-db.sh` is NOT collected for execution

#### Scenario: User and project hooks are combined in order
- **WHEN** `~/.config/epi/hooks/post-launch.d/notify.sh` exists
- **AND** `.epi/hooks/post-launch.d/setup.sh` exists
- **AND** the instance name is `default`
- **THEN** execution order is: `notify.sh` (user), `setup.sh` (project)

#### Scenario: Nix-config hooks follow file-based hooks
- **WHEN** `.epi/hooks/post-launch.d/setup.sh` exists
- **AND** the target descriptor contains `hooks.post-launch` with `["/nix/store/...-check"]`
- **THEN** execution order is: `setup.sh` (project), `/nix/store/...-check` (nix-config)

#### Scenario: No hook directories exist and no nix-config hooks
- **WHEN** neither file-based hook directories nor target descriptor hooks exist
- **THEN** no hooks are collected and launch proceeds normally

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

### Requirement: Post-launch hooks run after SSH is ready
The `post-launch` hook point SHALL execute host-side hook scripts after the VM's SSH connection has been confirmed ready. Scripts are discovered from `post-launch.d/` directories.

#### Scenario: Post-launch hooks run after successful SSH wait
- **WHEN** a user runs `epi launch dev --target .#dev`
- **AND** `.epi/hooks/post-launch.d/setup.sh` exists and is executable
- **THEN** `setup.sh` runs after SSH is confirmed ready

#### Scenario: Post-launch hooks do not run with --no-wait
- **WHEN** a user runs `epi launch dev --target .#dev --no-wait`
- **THEN** post-launch hooks do NOT run (SSH readiness is not confirmed)

### Requirement: Pre-stop hooks run before VM termination
The `pre-stop` hook point SHALL execute host-side hook scripts before the VM's systemd units are stopped. Scripts are discovered from `pre-stop.d/` directories.

#### Scenario: Pre-stop hooks run before stopping
- **WHEN** a user runs `epi stop dev`
- **AND** `.epi/hooks/pre-stop.d/cleanup.sh` exists and is executable
- **THEN** `cleanup.sh` runs before the VM's systemd units are terminated
