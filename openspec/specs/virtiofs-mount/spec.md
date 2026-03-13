### Requirement: Mount host directory into guest via virtiofs
The `epi launch` command SHALL accept one or more `--mount` flags, each sharing a host directory with the guest VM using virtiofsd and cloud-hypervisor's `--fs` support. Each shared directory SHALL be mounted at the same absolute path inside the guest as the resolved source directory on the host. The path passed to `--mount` MAY be absolute, relative to the current working directory, or use `~` to refer to the user's home directory. The system SHALL resolve all mount paths to absolute paths before use. Relative paths SHALL be resolved against the current working directory. `~` or `~/...` SHALL be expanded to `$HOME` or `$HOME/...`. The resolved path MUST be a directory; passing a file path SHALL produce an error.

#### Scenario: Mount current directory with --mount flag (no argument)
- **WHEN** user runs `epi launch --target .#config --mount` from `/home/user/project`
- **THEN** the current working directory is shared into the guest at `/home/user/project`

#### Scenario: Mount explicit absolute path with --mount flag
- **WHEN** user runs `epi launch --target .#config --mount /home/user/project`
- **THEN** `/home/user/project` on the host is shared into the guest at `/home/user/project`

#### Scenario: Mount relative path with --mount flag
- **WHEN** user runs `epi launch --target .#config --mount src` from `/home/user/project`
- **THEN** `/home/user/project/src` on the host is shared into the guest at `/home/user/project/src`

#### Scenario: Mount parent directory traversal with --mount flag
- **WHEN** user runs `epi launch --target .#config --mount ../shared` from `/home/user/project`
- **THEN** `/home/user/shared` on the host is shared into the guest at `/home/user/shared`

#### Scenario: Mount tilde path with --mount flag
- **WHEN** user runs `epi launch --target .#config --mount ~/projects` and `$HOME` is `/home/user`
- **THEN** `/home/user/projects` on the host is shared into the guest at `/home/user/projects`

#### Scenario: Mount multiple paths with repeated --mount flags
- **WHEN** user runs `epi launch --target .#config --mount /home/user/project --mount ~/secrets`
- **THEN** both `/home/user/project` and the resolved `~/secrets` path are shared into the guest at their respective absolute paths

#### Scenario: No --mount flag
- **WHEN** user runs `epi launch --target .#config` without `--mount`
- **THEN** no virtiofsd is started and no `--fs` argument is passed to cloud-hypervisor

#### Scenario: --mount with a file path fails
- **WHEN** user passes a file path (not a directory) to `--mount`
- **THEN** the system reports an error indicating the path must be a directory

### Requirement: virtiofsd daemon lifecycle

The system SHALL start one `virtiofsd` daemon per mount path before launching cloud-hypervisor and SHALL track all their PIDs for cleanup.

#### Scenario: One virtiofsd per mount path
- **WHEN** `--mount` is used N times during `epi launch`
- **THEN** N virtiofsd processes are started, each with a unique vhost-user socket (`virtiofsd-<n>.sock`) in the instance state directory
- **AND** the system waits for each socket to appear before launching cloud-hypervisor

#### Scenario: virtiofsd stopped on instance down
- **WHEN** user runs `epi stop` on an instance that was started with one or more `--mount` flags
- **THEN** all virtiofsd processes are terminated along with the VM and passt processes

#### Scenario: virtiofsd binary not found
- **WHEN** `--mount` is used but `virtiofsd` is not found in PATH
- **THEN** the system exits with an actionable error indicating virtiofsd is required and how to resolve it

### Requirement: Mount paths persist in host instance state

When `epi launch` is called with one or more `--mount` paths, the system SHALL persist those paths as a JSON array in the `mounts` field of `state.json`. When `epi start` restarts a stopped instance that has mount paths in `state.json`, the system SHALL re-launch virtiofsd for each saved path before starting cloud-hypervisor.

#### Scenario: Mount paths saved on launch
- **WHEN** user runs `epi launch --target .#config --mount /home/user/project`
- **THEN** `/home/user/project` is stored in the `mounts` array in `state.json`

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
