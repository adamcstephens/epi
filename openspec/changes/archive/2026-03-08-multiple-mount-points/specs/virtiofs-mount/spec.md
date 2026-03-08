## MODIFIED Requirements

### Requirement: Mount host directory into guest via virtiofs

The `epi up` command SHALL accept one or more `--mount` flags, each sharing a host directory with the guest VM using virtiofsd and cloud-hypervisor's `--fs` support. Each shared directory SHALL be mounted at the same absolute path inside the guest as the source directory on the host.

#### Scenario: Mount current directory with --mount flag (no argument)
- **WHEN** user runs `epi up --target .#config --mount` from `/home/user/project`
- **THEN** the current working directory is shared into the guest at `/home/user/project`

#### Scenario: Mount explicit path with --mount flag
- **WHEN** user runs `epi up --target .#config --mount /home/user/project`
- **THEN** `/home/user/project` on the host is shared into the guest at `/home/user/project`

#### Scenario: Mount multiple paths with repeated --mount flags
- **WHEN** user runs `epi up --target .#config --mount /home/user/project --mount /home/user/secrets`
- **THEN** both `/home/user/project` and `/home/user/secrets` are shared into the guest at their respective absolute paths

#### Scenario: No --mount flag
- **WHEN** user runs `epi up --target .#config` without `--mount`
- **THEN** no virtiofsd is started and no `--fs` argument is passed to cloud-hypervisor

### Requirement: virtiofsd daemon lifecycle

The system SHALL start one `virtiofsd` daemon per mount path before launching cloud-hypervisor and SHALL track all their PIDs for cleanup.

#### Scenario: One virtiofsd per mount path
- **WHEN** `--mount` is used N times during `epi up`
- **THEN** N virtiofsd processes are started, each with a unique vhost-user socket (`virtiofsd-<n>.sock`) in the instance state directory
- **AND** the system waits for each socket to appear before launching cloud-hypervisor

#### Scenario: virtiofsd stopped on instance down
- **WHEN** user runs `epi down` on an instance that was started with one or more `--mount` flags
- **THEN** all virtiofsd processes are terminated along with the VM and passt processes

#### Scenario: virtiofsd binary not found
- **WHEN** `--mount` is used but `virtiofsd` is not on `$PATH` and `EPI_VIRTIOFSD_BIN` is not set
- **THEN** the system reports an error indicating virtiofsd is required and suggests setting `EPI_VIRTIOFSD_BIN`

### Requirement: Cloud-init configures guest mounts at runtime

The system SHALL add a `mounts` directive to the cloud-init user-data for each `--mount` path used during `epi up`, so the guest automatically mounts all virtiofs shares.

#### Scenario: Cloud-init user-data includes one mount entry per --mount flag
- **WHEN** `--mount` is used N times during `epi up`
- **THEN** the generated cloud-init user-data includes N entries in the `mounts` block, each mounting the corresponding virtiofs tag to the same absolute path as the host source directory, with type `virtiofs`

#### Scenario: Cloud-init user-data without mount
- **WHEN** `epi up` is run without `--mount`
- **THEN** the generated cloud-init user-data contains no `mounts` block

### Requirement: Guest user UID matches host when cloud-init manages the user

When cloud-init creates the guest user (user does not already exist in the NixOS config), the system SHALL set the guest user's UID to match the host user's UID so that virtiofs file ownership is correct.

#### Scenario: UID set when cloud-init creates user with mount
- **WHEN** `--mount` is used and the user does not exist in the NixOS config
- **THEN** the cloud-init user-data includes `uid: <host_uid>` for the user entry, where `<host_uid>` is the UID of the user running `epi up`

#### Scenario: UID not set when user already exists
- **WHEN** `--mount` is used but the user already exists in the NixOS config
- **THEN** the cloud-init user-data does not include a `uid` field (cloud-init cannot change UID of existing users)

### Requirement: Guest kernel supports virtiofs

The NixOS guest configuration SHALL include the `virtiofs` kernel module in available kernel modules so that `mount -t virtiofs` works at runtime.

#### Scenario: virtiofs module available in guest
- **WHEN** a VM is booted from an epi NixOS image
- **THEN** the `virtiofs` kernel module is available for loading (present in `boot.initrd.availableKernelModules`)
