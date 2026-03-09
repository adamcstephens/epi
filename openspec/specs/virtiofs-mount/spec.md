### Requirement: Mount host directory into guest via virtiofs

The `epi up` command SHALL accept one or more `--mount` flags, each sharing a host directory with the guest VM using virtiofsd and cloud-hypervisor's `--fs` support. Each shared directory SHALL be mounted at the same absolute path inside the guest as the source directory on the host. The path passed to `--mount` MUST be a directory; passing a file path SHALL produce an error.

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

#### Scenario: --mount with a file path fails
- **WHEN** user passes a file path (not a directory) to `--mount`
- **THEN** the system reports an error indicating the path must be a directory

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

### Requirement: Seed ISO includes mount path list

The system SHALL add a plain text file named `epi-mounts` to the cloud-init seed ISO when `--mount` is used during `epi launch`. Each mount path SHALL appear on its own line. When no `--mount` flags are given, `epi-mounts` SHALL NOT be included in the ISO.

#### Scenario: epi-mounts file written to seed ISO with mounts
- **WHEN** user runs `epi launch --target .#config --mount /home/user/project --mount /home/user/data`
- **THEN** the seed ISO contains an `epi-mounts` file with `/home/user/project` and `/home/user/data` on separate lines

#### Scenario: epi-mounts absent when no mounts specified
- **WHEN** user runs `epi launch --target .#config` without `--mount`
- **THEN** the seed ISO does not contain an `epi-mounts` file

### Requirement: NixOS guest has a systemd generator for virtiofs mounts

The NixOS guest image SHALL include a systemd generator that runs on every boot. The generator SHALL locate the block device labeled `cidata`, mount it read-only, read `epi-mounts` (if present), and emit a systemd `.mount` unit in the generator output directory for each path. The generator SHALL be a no-op if `epi-mounts` is absent or empty.

#### Scenario: Generator creates mount units on boot when epi-mounts exists
- **WHEN** the guest boots and the cidata volume contains an `epi-mounts` file with N paths
- **THEN** N `.mount` units are present in `/run/systemd/system/` and each virtiofs path is mounted

#### Scenario: Generator is a no-op when epi-mounts is absent
- **WHEN** the guest boots and the cidata volume has no `epi-mounts` file
- **THEN** no mount units are generated and no mounts are attempted

### Requirement: Mount paths persist in host instance state

When `epi launch` is called with one or more `--mount` paths, the system SHALL persist those paths in `~/.local/state/epi/<instance>/mounts` (one per line). When `epi start` restarts a stopped instance that has a `mounts` file, the system SHALL re-launch virtiofsd for each saved path before starting cloud-hypervisor.

#### Scenario: Mount paths saved on launch
- **WHEN** user runs `epi launch --target .#config --mount /home/user/project`
- **THEN** `/home/user/project` is written to `~/.local/state/epi/<instance>/mounts`

#### Scenario: virtiofsd restarted on epi start
- **WHEN** user runs `epi start` on an instance that was originally launched with `--mount /home/user/project`
- **THEN** virtiofsd is started for `/home/user/project` before cloud-hypervisor boots the guest

#### Scenario: No virtiofsd on start when no mounts were saved
- **WHEN** user runs `epi start` on an instance that was launched without `--mount`
- **THEN** no virtiofsd is started

### Requirement: Cloud-init does not configure guest mounts

The cloud-init user-data SHALL NOT contain `write_files` or `runcmd` entries related to virtiofs mount units or mount directories. Mount setup is handled entirely by the NixOS systemd generator reading from the seed ISO.

#### Scenario: user-data contains no mount entries
- **WHEN** `epi launch` is run with one or more `--mount` flags
- **THEN** the generated cloud-init user-data contains no `write_files` or `runcmd` blocks for mounts

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
