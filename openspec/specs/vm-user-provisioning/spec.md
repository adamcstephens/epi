## Purpose
Define how epi provisions a user account in the VM that matches the host user, using cloud-init NoCloud seed ISOs generated at launch time.

## Requirements

### Requirement: VM creates a user account matching the host username
The system SHALL create a user account in the VM whose username matches the host user who invoked `epi up`. The account SHALL be a normal user with a home directory and membership in the `wheel` group.

#### Scenario: User account exists after VM boot
- **WHEN** a user runs `epi up` with a valid target
- **THEN** the VM boots and cloud-init creates a user account whose name matches the host `$USER`
- **AND** the account has a home directory at `/home/<username>`
- **AND** the account is a member of the `wheel` group

### Requirement: epi generates a cloud-init NoCloud seed ISO
The system SHALL generate a cloud-init NoCloud seed ISO at provision time containing `user-data` and `meta-data` derived from the host environment.

#### Scenario: Seed ISO created during provisioning
- **WHEN** `epi up` provisions a new instance
- **THEN** epi creates a `user-data` file with the host username, `wheel` group, passwordless sudo, and SSH public keys
- **AND** epi creates a `meta-data` file with the instance name as `instance-id` and `local-hostname`
- **AND** epi invokes `genisoimage` to produce an ISO labeled `cidata` from these files
- **AND** the seed ISO is written to the runtime directory as `<instance>.cidata.iso`

#### Scenario: Seed ISO attached to cloud-hypervisor
- **WHEN** cloud-hypervisor is launched for the instance
- **THEN** the seed ISO is attached as an additional `--disk` argument (read-only)
- **AND** cloud-init inside the VM detects the NoCloud datasource and reads the seed

### Requirement: Host SSH public keys included in seed
The system SHALL read the host user's SSH public keys from `~/.ssh/*.pub` and include them in the cloud-init `user-data` for key-based SSH access.

#### Scenario: Public keys collected and included
- **WHEN** `epi up` provisions an instance and the host user has files matching `~/.ssh/*.pub`
- **THEN** the contents of those files are included in `user-data` under `ssh_authorized_keys`

#### Scenario: No SSH keys available
- **WHEN** the host user has no SSH public keys in `~/.ssh/`
- **THEN** the VM still boots and cloud-init still creates the user
- **AND** epi logs a warning that no SSH keys were found
- **AND** the `ssh_authorized_keys` field is omitted from `user-data`

### Requirement: Passwordless sudo for matching user
The cloud-init `user-data` SHALL configure the matching user with passwordless sudo access.

#### Scenario: User runs sudo without password
- **WHEN** the matching user runs a command with `sudo` in the VM
- **THEN** the command executes without prompting for a password

### Requirement: Serial console login available for matching user
The matching user SHALL be able to log in on the serial console without friction.

#### Scenario: Console login after boot
- **WHEN** a user attaches to the VM serial console after cloud-init has run
- **THEN** the user can log in as the matching user
- **AND** no password is required (empty password or auto-login)

### Requirement: genisoimage availability check
The system SHALL verify that `genisoimage` is available before attempting to create the seed ISO and fail with a clear error if it is not.

#### Scenario: genisoimage missing
- **WHEN** `epi up` attempts to generate a seed ISO and `genisoimage` is not found on `$PATH`
- **THEN** provisioning fails with an error message indicating that `genisoimage` (from `cdrkit`) is required
