## Purpose
Define the on-disk layout, file formats, and instance discovery rules for epi state, enabling any reimplementation to read, write, and discover instances compatibly.

## Requirements

### Requirement: State root is configurable via environment
The CLI SHALL resolve the state root directory in this order:
1. `$EPI_STATE_DIR` if set
2. `$HOME/.local/state/epi/` otherwise
3. `.epi-state` relative to the current working directory if `HOME` is also unset

All paths derived from the state root are stored and compared as absolute paths. Relative paths provided via environment variables are resolved against the current working directory at startup.

#### Scenario: EPI_STATE_DIR overrides default
- **WHEN** `EPI_STATE_DIR=/tmp/test-state` is set
- **THEN** the CLI stores and reads all instance state under `/tmp/test-state/`
- **AND** the default `~/.local/state/epi/` is not used

#### Scenario: Default path is used when EPI_STATE_DIR is absent
- **WHEN** `EPI_STATE_DIR` is not set and `HOME=/home/alice`
- **THEN** the CLI uses `/home/alice/.local/state/epi/` as the state root

### Requirement: Each instance occupies a dedicated subdirectory
The state root contains one subdirectory per instance, named by the instance name. The CLI SHALL create parent directories as needed (mode `0o755`) when storing new state.

```
<state-root>/
  <instance-name>/
    target          # required — flake target string
    runtime         # runtime metadata; absent when stopped
    mounts          # virtiofs mount paths; absent when no mounts configured
    disk.img        # writable overlay disk image (Nix-store disks only)
    cidata/         # staging directory for cloud-init seed files
      user-data     # cloud-init user-data YAML
      meta-data     # cloud-init meta-data YAML
      epi-mounts    # mount paths file (present only when mounts configured)
    cidata.iso      # cloud-init NoCloud seed ISO
    passt.sock      # vhost-user socket for passt networking
    serial.sock     # Unix socket for serial console (created by cloud-hypervisor)
    id_ed25519      # generated SSH private key (only with --generate-ssh-key)
    id_ed25519.pub  # generated SSH public key (only with --generate-ssh-key)
```

### Requirement: target file format
The `target` file contains the flake reference string (`<flake-ref>#<config-name>`) as a single line. A trailing newline is written; leading and trailing whitespace is stripped when reading. An empty or missing file means no stored target.

#### Scenario: Target file round-trips
- **WHEN** the CLI stores target `.#dev-a` for instance `dev-a`
- **THEN** reading the `target` file yields `.#dev-a`

### Requirement: runtime file format
The `runtime` file is a key=value plain-text file, one entry per line (`key=value`). Fields:

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `unit_id` | 8-char lowercase hex | Yes | Identifies the systemd unit session for this launch |
| `serial_socket` | absolute path | Yes | Path to the serial Unix domain socket |
| `disk` | absolute path | Yes | Path to the writable disk image used at launch |
| `ssh_port` | integer | No | Host TCP port forwarded to VM port 22 |
| `ssh_key_path` | absolute path | No | Path to the generated SSH private key |

A runtime file is treated as absent if `unit_id` is missing or empty. Unknown keys are ignored. Fields are written in the order listed above, omitting absent optional fields.

#### Scenario: Runtime file round-trips required fields
- **WHEN** the CLI writes a runtime with `unit_id=abc12345`, `serial_socket=/path/serial.sock`, `disk=/path/disk.img`
- **THEN** reading the file yields the same values

#### Scenario: Runtime file tolerates missing optional fields
- **WHEN** a runtime file lacks `ssh_port` and `ssh_key_path`
- **THEN** the CLI loads the runtime successfully
- **AND** `ssh_port` and `ssh_key_path` are treated as absent

### Requirement: mounts file format
The `mounts` file contains one absolute host directory path per line. Blank lines are ignored when reading. An empty or missing file means no mounts were configured. The file is written with a trailing newline after the last path.

#### Scenario: Mounts file round-trips
- **WHEN** the CLI stores mounts `["/home/alice/src", "/data"]`
- **THEN** reading the file yields `["/home/alice/src", "/data"]` in the same order

### Requirement: Instance discovery
An entry in the state root is a known instance if and only if:
- It is a directory, **and**
- It contains a `target` file with non-empty content after trimming

The `list` command scans the state root for qualifying directories and returns instances sorted alphabetically by instance name.

#### Scenario: Only directories with target files are listed
- **WHEN** the state root contains `dev-a/target`, `dev-b/` (no target file), and a plain file `README`
- **THEN** `epi list` returns only `dev-a`

#### Scenario: Empty state root returns empty list
- **WHEN** the state root directory does not exist or is empty
- **THEN** `epi list` returns no instances
