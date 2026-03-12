## MODIFIED Requirements

### Requirement: epi-init service handles all guest initialization
The NixOS guest image SHALL include an `epi-init.service` systemd oneshot service that runs on every boot. The service SHALL mount the epidata ISO at `/run/epi-init/epidata`, read `epi.json`, create the user account, set the hostname, set up SSH authorized keys, and set up virtiofs mounts — in that order. The service SHALL leave the epidata ISO mounted at `/run/epi-init/epidata` for use by `epi-init-hooks.service`. The service SHALL NOT execute guest hook scripts — hook execution is handled by `epi-init-hooks.service`.

#### Scenario: epi-init runs on first boot
- **WHEN** a VM boots for the first time with an epidata ISO attached
- **THEN** epi-init mounts the epidata ISO at `/run/epi-init/epidata`
- **AND** creates the user, sets the hostname, configures SSH keys, and mounts virtiofs filesystems

- **AND** does NOT execute guest hook scripts
- **AND** the user can SSH into the VM after epi-init completes (without waiting for hooks)

#### Scenario: epi-init runs on subsequent boots
- **WHEN** a VM reboots (not first boot)
- **THEN** epi-init runs again, skips user creation (user already exists), sets hostname, re-mounts virtiofs filesystems
- **AND** writes the username to `/run/epi-init/username`
- **AND** does NOT execute guest hook scripts
