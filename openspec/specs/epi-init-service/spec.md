## Purpose
Define the epi-init systemd service that handles all guest-side initialization: user creation, hostname, SSH keys, and virtiofs mounts.

## Requirements

### Requirement: epi-init service handles all guest initialization
The NixOS guest image SHALL include an `epi-init.service` systemd oneshot service that runs on every boot. The service SHALL mount the epidata ISO, read `epi.json`, create the user account, set the hostname, and set up virtiofs mounts — in that order. The service SHALL replace both cloud-init and the epi-mounts systemd generator.

#### Scenario: epi-init runs on first boot
- **WHEN** a VM boots for the first time with an epidata ISO attached
- **THEN** epi-init creates the user, sets the hostname, and mounts any virtiofs filesystems
- **AND** the user can SSH into the VM after boot completes

#### Scenario: epi-init runs on subsequent boots
- **WHEN** a VM reboots (not first boot)
- **THEN** epi-init runs again, skips user creation (user already exists), sets hostname, and re-mounts virtiofs filesystems

### Requirement: epi-init waits for epidata block device
The epi-init service SHALL locate the block device labeled `epidata` using `blkid -L epidata`. If the device is not found, the service SHALL exit successfully (no-op) to allow VMs without epidata to boot.

#### Scenario: epidata device present
- **WHEN** epi-init runs and a block device labeled `epidata` exists
- **THEN** the service mounts it read-only and reads `epi.json`

#### Scenario: epidata device absent
- **WHEN** epi-init runs and no block device labeled `epidata` exists
- **THEN** the service exits with success and takes no action

### Requirement: epi-init reads epi.json
The service SHALL read a single `epi.json` file from the epidata ISO using `jq`. The JSON structure:

```json
{
  "hostname": "<instance-name>",
  "user": {
    "name": "<username>",
    "uid": 1000,
    "ssh_authorized_keys": ["ssh-ed25519 ..."]
  },
  "mounts": ["/path1", "/path2"]
}
```

Field presence:
- `hostname` is always present
- `user.name` is always present
- `user.uid` is present only when the user needs to be created with a specific UID
- `user.ssh_authorized_keys` is present only when keys exist
- `mounts` is present only when mount paths were specified

#### Scenario: Full epi.json with all fields
- **WHEN** epi-init reads `epi.json` containing hostname, user with uid and keys, and mounts
- **THEN** the service processes all sections in order: user creation, hostname, mounts

#### Scenario: Minimal epi.json without optional fields
- **WHEN** epi-init reads `epi.json` with only hostname and user.name
- **THEN** the service creates the user without a specific UID, sets hostname, and skips mounts

### Requirement: epi-init creates user from epi.json
The service SHALL create the user account specified in `user.name` if it does not already exist, using `useradd` with home directory (`-m`), group wheel (`-G wheel`), and shell `/run/current-system/sw/bin/bash` (`-s`). If `user.uid` is present, the UID SHALL be set (`-u`). If the user already exists, user creation SHALL be skipped. Passwordless sudo SHALL be configured via NixOS `security.sudo.wheelNeedsPassword = false`.

#### Scenario: New user created
- **WHEN** epi-init reads `epi.json` with `user.name=alice` and `user.uid=1000`
- **AND** user `alice` does not exist in the guest
- **THEN** the service creates user `alice` with UID 1000, group `wheel`, home directory `/home/alice`, shell `/run/current-system/sw/bin/bash`, and passwordless sudo

#### Scenario: Existing user skipped
- **WHEN** epi-init reads `epi.json` with `user.name=alice`
- **AND** user `alice` already exists in the guest
- **THEN** the service does not attempt to create the user
- **AND** SSH authorized keys are still updated

### Requirement: epi-init installs SSH authorized keys
The service SHALL read `user.ssh_authorized_keys` from `epi.json` and write them to `/etc/ssh/authorized_keys.d/<username>`. The directory `/etc/ssh/authorized_keys.d/` SHALL be created if needed. The file SHALL have permissions 644.

#### Scenario: SSH keys written for new user
- **WHEN** epi-init creates a new user and `epi.json` contains two SSH keys
- **THEN** `/etc/ssh/authorized_keys.d/<username>` contains both keys

#### Scenario: SSH keys updated for existing user
- **WHEN** epi-init runs and the user already exists
- **THEN** `/etc/ssh/authorized_keys.d/<username>` is overwritten with keys from `epi.json`

#### Scenario: No SSH keys in epi.json
- **WHEN** `epi.json` has no `ssh_authorized_keys` field or it is empty
- **THEN** no authorized keys file is created or modified

### Requirement: epi-init sets hostname
The service SHALL set the system hostname to the value of `hostname` from `epi.json` using the `hostname` command (runtime only).

#### Scenario: Hostname set on boot
- **WHEN** epi-init reads `epi.json` with `hostname=myvm`
- **THEN** the system hostname is set to `myvm`

### Requirement: epi-init creates and starts virtiofs mount units
When `mounts` is present in `epi.json`, the service SHALL for each path (zero-indexed as `i`): create a systemd `.mount` unit file in `/run/systemd/system/` with `Type=virtiofs` and `What=hostfs-<i>`, create the mount point directory with `mkdir -p` owned by the user, then after all units are written run `systemctl daemon-reload` and start all mount units.

#### Scenario: Mount units created and started
- **WHEN** epi-init reads `epi.json` with `mounts` containing two paths
- **THEN** two `.mount` unit files are written to `/run/systemd/system/`
- **AND** both mount point directories are created
- **AND** `systemctl daemon-reload` is called
- **AND** both mount units are started

#### Scenario: No mounts field
- **WHEN** `epi.json` has no `mounts` field
- **THEN** no mount units are created and no mounts are attempted

#### Scenario: Mounts happen after user creation
- **WHEN** epi-init processes both user and mounts from `epi.json`
- **THEN** user creation and home directory setup complete before any mount units are started

### Requirement: epi-init service ordering
The `epi-init.service` SHALL be `Type=oneshot` with `RemainAfterExit=yes`. It SHALL run `After=local-fs.target` and `Before=multi-user.target sshd.service`. It SHALL be `WantedBy=multi-user.target`.

#### Scenario: Service completes before SSH is available
- **WHEN** epi-init runs during boot
- **THEN** it completes before `sshd.service` starts
- **AND** the user account and SSH keys are in place when SSH becomes available

### Requirement: cloud-init is not present in the guest
The NixOS guest configuration SHALL NOT enable cloud-init. The `services.cloud-init.enable` option SHALL be removed.

#### Scenario: Guest boots without cloud-init
- **WHEN** a VM boots from the epi NixOS image
- **THEN** no cloud-init services are running
- **AND** the cloud-init package is not in the system closure
