## MODIFIED Requirements

### Requirement: Guest init hooks are executed as the provisioned user
The `epi-init-hooks.service` SHALL execute guest hook scripts from the seed ISO after `epi-init.service` completes all initialization steps and after `network-online.target` is reached. After seed ISO hooks, the service SHALL execute Nix-declared guest-init hooks (baked into the VM image). Scripts SHALL be executed sequentially using `su - <username> -c <script>`, where the username is read from `/run/epi-init/epidata/epi.json`. If a hook script exits non-zero, the service SHALL log the failure and continue with remaining hooks.

#### Scenario: Guest hooks run after init as user with network
- **WHEN** a VM boots with guest hook scripts in the seed ISO
- **AND** the provisioned user is `alice`
- **THEN** each hook script runs as `alice` after user creation, hostname, SSH keys, and mounts are complete
- **AND** each hook script has network connectivity

#### Scenario: Nix-declared guest hooks run after seed ISO hooks
- **WHEN** seed ISO contains file-based guest hooks
- **AND** the epi-init-hooks service has Nix-declared guest hooks baked in
- **THEN** seed ISO hooks execute first, then Nix-declared hooks execute

#### Scenario: Guest hook failure does not block boot
- **WHEN** a guest hook script exits with code 1
- **THEN** the failure is logged to the console
- **AND** remaining hook scripts still execute
- **AND** the VM continues booting (sshd starts normally)

#### Scenario: Guest hooks run on first boot only
- **WHEN** a VM reboots (not first provision)
- **THEN** guest hook scripts from the seed ISO do NOT re-execute
- **AND** Nix-declared guest hooks do NOT re-execute
