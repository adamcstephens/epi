## MODIFIED Requirements

### Requirement: epi-init service handles all guest initialization
The NixOS guest image SHALL include an `epi-init.service` systemd oneshot service that runs on every boot. The service SHALL mount the epidata ISO, read `epi.json`, create the user account, set the hostname, and set up virtiofs mounts — in that order. After all existing init steps are complete, the service SHALL execute any guest hook scripts found in the seed ISO as the provisioned user. The service SHALL replace both cloud-init and the epi-mounts systemd generator.

#### Scenario: epi-init runs on first boot
- **WHEN** a VM boots for the first time with an epidata ISO attached
- **THEN** epi-init creates the user, sets the hostname, mounts any virtiofs filesystems, and runs guest hook scripts as the provisioned user
- **AND** the user can SSH into the VM after boot completes

#### Scenario: epi-init runs on subsequent boots
- **WHEN** a VM reboots (not first boot)
- **THEN** epi-init runs again, skips user creation (user already exists), sets hostname, re-mounts virtiofs filesystems, and does NOT re-execute guest hook scripts
