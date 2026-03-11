## ADDED Requirements

### Requirement: Guest init hooks are collected and embedded in seed ISO
The system SHALL collect guest hook scripts from `guest-init.d/` directories at two layers: user-level (`~/.config/epi/hooks/guest-init.d/`) and project-level (`.epi/hooks/guest-init.d/`). Within each layer, top-level executable files and instance-specific `<instance>/` executable files are collected using the same discovery and ordering rules as host hooks. Collected scripts SHALL be embedded into the seed ISO at provision time, alongside `epi.json`.

#### Scenario: Guest hooks are embedded in seed ISO
- **WHEN** `.epi/hooks/guest-init.d/install-tools.sh` exists and is executable
- **AND** a user runs `epi launch dev --target .#dev`
- **THEN** the seed ISO contains the `install-tools.sh` script

#### Scenario: Multiple layers are embedded in order
- **WHEN** `~/.config/epi/hooks/guest-init.d/dotfiles.sh` exists
- **AND** `.epi/hooks/guest-init.d/project-setup.sh` exists
- **THEN** the seed ISO contains both scripts with user-level ordered before project-level

#### Scenario: No guest hooks exist
- **WHEN** no `guest-init.d/` directories exist at any layer
- **THEN** the seed ISO is created without hook scripts (same as current behavior)

### Requirement: Guest init hooks are executed as the provisioned user
The `epi-init` service SHALL execute guest hook scripts from the seed ISO after completing all other initialization steps (user creation, hostname, SSH keys, mounts). Scripts SHALL be executed sequentially in their embedded order using `su - <username> -c <script>`. If a hook script exits non-zero, the service SHALL log the failure and continue with remaining hooks.

#### Scenario: Guest hooks run after init as user
- **WHEN** a VM boots with guest hook scripts in the seed ISO
- **AND** the provisioned user is `alice`
- **THEN** each hook script runs as `alice` after user creation, hostname, SSH keys, and mounts are complete

#### Scenario: Guest hook failure does not block boot
- **WHEN** a guest hook script exits with code 1
- **THEN** the failure is logged to the console
- **AND** remaining hook scripts still execute
- **AND** the VM continues booting (sshd starts normally)

#### Scenario: Guest hooks run on first boot only
- **WHEN** a VM reboots (not first provision)
- **THEN** guest hook scripts from the seed ISO do NOT re-execute
