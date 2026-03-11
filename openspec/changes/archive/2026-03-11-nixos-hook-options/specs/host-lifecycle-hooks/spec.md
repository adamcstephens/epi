## MODIFIED Requirements

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
