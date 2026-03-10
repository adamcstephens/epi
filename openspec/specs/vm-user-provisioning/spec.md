## Purpose
Define how epi provisions a user account in the VM that matches the host user, using epidata seed ISOs generated at launch time.

## Requirements

### Requirement: VM creates a user account matching the host username
The system SHALL create a user account in the VM whose username matches the host user who invoked `epi up`. The account SHALL be a normal user with a home directory and membership in the `wheel` group.

#### Scenario: User account exists after VM boot
- **WHEN** a user runs `epi up` with a valid target
- **THEN** the VM boots and epi-init creates a user account whose name matches the host `$USER`
- **AND** the account has a home directory at `/home/<username>`
- **AND** the account is a member of the `wheel` group

### Requirement: epi generates a seed ISO
The system SHALL generate a seed ISO at provision time containing a single `epi.json` file derived from the host environment. The ISO SHALL use the volume label `epidata`.

#### Scenario: Seed ISO created during provisioning
- **WHEN** `epi up` provisions a new instance
- **THEN** epi creates an `epi.json` file with hostname, user data (name, uid, SSH keys), and mount paths
- **AND** epi invokes `genisoimage` to produce an ISO labeled `epidata` containing `epi.json`
- **AND** the seed ISO is written to the instance directory

#### Scenario: Seed ISO attached to cloud-hypervisor
- **WHEN** cloud-hypervisor is launched for the instance
- **THEN** the seed ISO is attached as an additional `--disk` argument (read-only)

### Requirement: Passwordless sudo for matching user
The NixOS guest configuration SHALL set `security.sudo.wheelNeedsPassword = false` so that wheel group members have passwordless sudo.

#### Scenario: User runs sudo without password
- **WHEN** the matching user runs a command with `sudo` in the VM
- **THEN** the command executes without prompting for a password

### Requirement: Serial console login available for matching user
The matching user SHALL be able to log in on the serial console without friction.

#### Scenario: Console login after boot
- **WHEN** a user attaches to the VM serial console after epi-init has run
- **THEN** the user can log in as the matching user
- **AND** no password is required (empty password or auto-login)

### Requirement: genisoimage availability check
The system SHALL verify that `genisoimage` is available before attempting to create the seed ISO and fail with a clear error if it is not.

#### Scenario: genisoimage missing
- **WHEN** `epi up` attempts to generate a seed ISO and `genisoimage` is not found on `$PATH`
- **THEN** provisioning fails with an error message indicating that `genisoimage` (from `cdrkit`) is required

### Requirement: epi.json structure
The `epi.json` file in the seed ISO SHALL use JSON format with the following structure:

```json
{
  "hostname": "<instance-name>",
  "user": {
    "name": "<username>",
    "uid": <host_uid>,
    "ssh_authorized_keys": ["<key1>", "<key2>"]
  },
  "mounts": ["/path1", "/path2"]
}
```

Field rules:
- `hostname` is always emitted (the instance name)
- `user.name` is always emitted (the matching username)
- `user.uid` is emitted only when the username is **not** listed in the target's `configured_users`
- `user.ssh_authorized_keys` is emitted only when at least one public key was found; omitted when no keys are available
- `mounts` is emitted only when `--mount` was used; omitted when no mounts specified
- Each SSH key is the full contents of one `~/.ssh/*.pub` file; if `--generate-ssh-key` was used, the generated public key is appended

#### Scenario: New user gets uid
- **WHEN** the matched username is not in `configured_users`
- **THEN** `epi.json` includes `user.uid` set to the host user's UID

#### Scenario: Existing NixOS user gets only name and keys
- **WHEN** the matched username is already in `configured_users`
- **THEN** `epi.json` contains `user.name` and `user.ssh_authorized_keys` (if keys exist)
- **AND** `user.uid` is omitted

### Requirement: Seed ISO is labeled epidata and uses Joliet+Rock Ridge
The seed ISO SHALL be created with:
- Volume label: `epidata`
- Joliet extensions enabled (`-joliet`)
- Rock Ridge extensions enabled (`-rock`)

The ISO is written to `<instance-dir>/epidata.iso` and passed to cloud-hypervisor as a read-only disk attachment.

#### Scenario: ISO created with epidata label
- **WHEN** epi creates the seed ISO
- **THEN** the ISO volume label is `epidata`
- **AND** the ISO file is named `epidata.iso`
