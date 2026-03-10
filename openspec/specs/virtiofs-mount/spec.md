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

### Requirement: Guest kernel supports virtiofs

The NixOS guest configuration SHALL include the `virtiofs` kernel module in available kernel modules so that `mount -t virtiofs` works at runtime.

#### Scenario: virtiofs module available in guest
- **WHEN** a VM is booted from an epi NixOS image
- **THEN** the `virtiofs` kernel module is available for loading (present in `boot.initrd.availableKernelModules`)
