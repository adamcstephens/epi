## MODIFIED Requirements

### Requirement: epi-init service handles all guest initialization
The NixOS guest image SHALL include an `epi-init.service` systemd oneshot service that runs on every boot. The service SHALL mount the epidata ISO, read `epi.json`, create the user account, set the hostname, and set up virtiofs mounts — in that order. After all existing init steps are complete, the service SHALL execute any guest hook scripts found in the seed ISO as the provisioned user. The service SHALL replace both cloud-init and the epi-mounts systemd generator. The service SHALL operate correctly when `/nix/store` is an overlayfs mount backed by the host store, without attempting to modify store paths or making assumptions about store path locality.

#### Scenario: epi-init runs on first boot
- **WHEN** a VM boots for the first time with an epidata ISO attached
- **THEN** epi-init creates the user, sets the hostname, mounts any virtiofs filesystems, and runs guest hook scripts as the provisioned user
- **AND** the user can SSH into the VM after boot completes

#### Scenario: epi-init runs on subsequent boots
- **WHEN** a VM reboots (not first boot)
- **THEN** epi-init runs again, skips user creation (user already exists), sets hostname, re-mounts virtiofs filesystems, and does NOT re-execute guest hook scripts

#### Scenario: epi-init works with overlayfs-backed /nix/store
- **WHEN** the VM boots with `/nix/store` mounted as an overlayfs (host lower, guest upper)
- **THEN** epi-init executes successfully using binaries from the overlayfs-merged store
- **AND** all init operations complete without errors related to store path access
