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
    state.json        # required — consolidated instance state
    disk.img          # writable overlay disk image (Nix-store disks only)
    cidata/           # staging directory for cloud-init seed files
      user-data       # cloud-init user-data YAML
      meta-data       # cloud-init meta-data YAML
      epi-mounts      # mount paths file (present only when mounts configured)
    cidata.iso        # cloud-init NoCloud seed ISO
    passt.sock        # vhost-user socket for passt networking
    serial.sock       # Unix socket for serial console (created by cloud-hypervisor)
    id_ed25519        # generated SSH private key (only with --generate-ssh-key)
    id_ed25519.pub    # generated SSH public key (only with --generate-ssh-key)
```

#### Scenario: Instance directory contains state.json
- **WHEN** the CLI creates a new instance `dev-a` with target `.#dev-a`
- **THEN** the file `<state-root>/dev-a/state.json` exists
- **AND** it contains valid JSON with a `target` field

### Requirement: state.json file format
The `state.json` file is a JSON object containing all instance state. The CLI SHALL use `serde_json` for reading and writing.

Top-level fields:

| Key | JSON Type | Required | Description |
|-----|-----------|----------|-------------|
| `target` | string | Yes | Flake reference string (`<flake-ref>#<config-name>`) |
| `mounts` | array of strings | No | Absolute host directory paths for virtiofs mounts. Absent or empty array means no mounts. |
| `runtime` | object or null | No | Runtime metadata. Absent or null when VM is stopped. |

Runtime object fields:

| Key | JSON Type | Required | Description |
|-----|-----------|----------|-------------|
| `unit_id` | string | Yes | 8-char lowercase hex identifying the systemd unit session |
| `serial_socket` | string | Yes | Absolute path to the serial Unix domain socket |
| `disk` | string | Yes | Absolute path to the writable disk image used at launch |
| `ssh_port` | integer | No | Host TCP port forwarded to VM port 22 |
| `ssh_key_path` | string | Yes | Absolute path to the generated SSH private key |

Unknown keys at any level SHALL be ignored when reading.

#### Scenario: state.json with target only
- **WHEN** an instance is created with target `.#dev-a` and no runtime or mounts
- **THEN** `state.json` contains `{"target": ".#dev-a"}`

#### Scenario: state.json with all fields
- **WHEN** an instance has target `.#dev-a`, mounts `["/home/alice/src"]`, and runtime with all fields
- **THEN** `state.json` contains a JSON object with `target`, `mounts`, and `runtime` keys
- **AND** `runtime` contains `unit_id`, `serial_socket`, `disk`, `ssh_port`, and `ssh_key_path`

#### Scenario: state.json round-trips runtime with optional fields absent
- **WHEN** a runtime is saved with `ssh_port` absent
- **THEN** reading the file yields `ssh_port = None`

### Requirement: Clearing runtime state
When the VM stops, the CLI SHALL remove the `runtime` key from `state.json` while preserving `target` and `mounts`. The CLI SHALL read the existing file, remove `runtime`, and write the result back.

#### Scenario: clear_runtime preserves target and mounts
- **WHEN** `state.json` has target, mounts, and runtime
- **AND** the CLI clears runtime
- **THEN** `state.json` still has `target` and `mounts`
- **AND** `runtime` key is absent

### Requirement: Instance discovery
An entry in the state root is a known instance if and only if:
- It is a directory, **and**
- It contains a `state.json` file with a non-empty `target` field

The `list` command scans the state root for qualifying directories and returns instances sorted alphabetically by instance name.

#### Scenario: Only directories with state.json are listed
- **WHEN** the state root contains `dev-a/state.json` (valid), `dev-b/` (no state.json), and a plain file `README`
- **THEN** `epi list` returns only `dev-a`

#### Scenario: Empty state root returns empty list
- **WHEN** the state root directory does not exist or is empty
- **THEN** `epi list` returns no instances
