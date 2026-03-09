## MODIFIED Requirements

### Requirement: Seed ISO includes mount path list

The system SHALL add a plain text file named `epi-mounts` to the cloud-init seed ISO when `--mount` is used during `epi launch`. Each mount path SHALL appear on its own line. When no `--mount` flags are given, `epi-mounts` SHALL NOT be included in the ISO.

#### Scenario: epi-mounts file written to seed ISO with mounts
- **WHEN** user runs `epi launch --target .#config --mount /home/user/project --mount /home/user/data`
- **THEN** the seed ISO contains an `epi-mounts` file with `/home/user/project` and `/home/user/data` on separate lines

#### Scenario: epi-mounts absent when no mounts specified
- **WHEN** user runs `epi launch --target .#config` without `--mount`
- **THEN** the seed ISO does not contain an `epi-mounts` file

### Requirement: NixOS guest has a systemd generator for virtiofs mounts

The NixOS guest image SHALL include a systemd generator that runs on every boot. The generator SHALL locate the block device labeled `cidata`, mount it read-only, read `epi-mounts` (if present), and emit a systemd `.mount` unit in the generator output directory for each path. Each unit SHALL include a `mkdir -p` pre-start step to ensure the mount point exists. The generator SHALL be a no-op if `epi-mounts` is absent or empty.

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
