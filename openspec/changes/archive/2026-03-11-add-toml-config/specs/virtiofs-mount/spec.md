## MODIFIED Requirements

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
