## Requirements

### Requirement: Config file is loaded from .epi/config.toml
The system SHALL look for a configuration file at `.epi/config.toml` relative to the current working directory. If the file does not exist, the system SHALL proceed as if no configuration was provided (all values absent). If the file exists but contains invalid TOML, the system SHALL exit non-zero with a parse error message that includes the file path and the parser's error detail.

#### Scenario: Config file exists and is valid
- **WHEN** `.epi/config.toml` exists with valid TOML content
- **THEN** the system parses it and makes values available for command resolution

#### Scenario: Config file does not exist
- **WHEN** `.epi/config.toml` does not exist
- **THEN** the system proceeds normally with no config defaults
- **AND** no error or warning is emitted

#### Scenario: Config file contains invalid TOML
- **WHEN** `.epi/config.toml` exists but contains syntax errors
- **THEN** the system exits non-zero
- **AND** the error message includes the file path `.epi/config.toml`
- **AND** the error message includes the TOML parse error detail

### Requirement: Config file supports target key
The configuration file SHALL accept an optional `target` key whose value is a string in `<flake-ref>#<config-name>` format. When present, this value SHALL be used as the default target for the `launch` command.

#### Scenario: Target provided in config
- **WHEN** `.epi/config.toml` contains `target = ".#dev"`
- **AND** the user runs `epi launch` without `--target`
- **THEN** the system uses `.#dev` as the target

#### Scenario: Target in config is malformed
- **WHEN** `.epi/config.toml` contains `target = "invalid"`
- **AND** the user runs `epi launch` without `--target`
- **THEN** the system exits non-zero with the same target format validation error as the CLI

### Requirement: Config file supports mounts key
The configuration file SHALL accept an optional `mounts` key whose value is an array of strings, each representing a path to a host directory. Paths MAY be absolute, relative to the project root (the parent directory of `.epi/`), or use `~` to refer to the user's home directory. The system SHALL resolve all config mount paths to absolute paths before use. Relative paths SHALL be resolved against the project root, NOT the current working directory. `~` or `~/...` SHALL be expanded to `$HOME` or `$HOME/...`. When present, these resolved paths SHALL be used as the default mount list for the `launch` command.

#### Scenario: Mounts with absolute paths
- **WHEN** `.epi/config.toml` contains `mounts = ["/home/user/projects"]`
- **AND** the user runs `epi launch` without `--mount`
- **THEN** the system uses `["/home/user/projects"]` as the mount list

#### Scenario: Mounts with relative paths resolve against project root
- **WHEN** `.epi/config.toml` contains `mounts = ["src", "./data"]`
- **AND** the project root (parent of `.epi/`) is `/home/user/myproject`
- **AND** the user runs `epi launch` from `/home/user/myproject/subdir`
- **THEN** the system resolves the mount list to `["/home/user/myproject/src", "/home/user/myproject/data"]`

#### Scenario: Mounts with parent directory traversal
- **WHEN** `.epi/config.toml` contains `mounts = ["../shared"]`
- **AND** the project root (parent of `.epi/`) is `/home/user/myproject`
- **THEN** the system resolves the mount list to `["/home/user/shared"]`

#### Scenario: Mounts with tilde expansion
- **WHEN** `.epi/config.toml` contains `mounts = ["~/projects", "~/.config"]`
- **AND** `$HOME` is `/home/user`
- **AND** the user runs `epi launch` without `--mount`
- **THEN** the system resolves the mount list to `["/home/user/projects", "/home/user/.config"]`

#### Scenario: Mounts is empty array in config
- **WHEN** `.epi/config.toml` contains `mounts = []`
- **AND** the user runs `epi launch` without `--mount`
- **THEN** the system uses no mounts

### Requirement: Config file supports disk_size key
The configuration file SHALL accept an optional `disk_size` key whose value is a string representing a disk size (e.g., `"40G"`, `"100G"`). When present, this value SHALL be used as the default disk size for the `launch` command.

#### Scenario: Disk size provided in config
- **WHEN** `.epi/config.toml` contains `disk_size = "80G"`
- **AND** the user runs `epi launch` without `--disk-size`
- **THEN** the system uses `80G` as the disk size

### Requirement: Config file supports cpus key
The configuration file SHALL accept an optional `cpus` key whose value is a positive integer. When present, this value SHALL be used as the default CPU count for the `launch` command, overriding the target descriptor's default.

#### Scenario: cpus provided in config
- **WHEN** `.epi/config.toml` contains `cpus = 4`
- **AND** the user runs `epi launch` without `--cpus`
- **THEN** the system uses 4 as the CPU count

### Requirement: Config file supports memory key
The configuration file SHALL accept an optional `memory` key whose value is a positive integer representing memory in mebibytes. When present, this value SHALL be used as the default memory for the `launch` command, overriding the target descriptor's default.

#### Scenario: memory provided in config
- **WHEN** `.epi/config.toml` contains `memory = 4096`
- **AND** the user runs `epi launch` without `--memory`
- **THEN** the system uses 4096 MiB as the memory size

### Requirement: Config file supports default_name key
The configuration file SHALL accept an optional `default_name` key whose value is a string. When present, this value SHALL be used as the default instance name when no positional instance name is provided to any command.

#### Scenario: default_name provided in config
- **WHEN** `.epi/config.toml` contains `default_name = "dev"`
- **AND** the user runs `epi launch` without a positional instance name
- **THEN** the system uses `dev` as the instance name

### Requirement: CLI arguments take precedence over config values
When the same option is provided both via CLI argument and in the config file, the CLI argument SHALL take precedence. This applies to `--target`, `--mount`, `--disk-size`, `--cpus`, and `--memory`.

#### Scenario: CLI target overrides config target
- **WHEN** `.epi/config.toml` contains `target = ".#dev"`
- **AND** the user runs `epi launch --target .#prod`
- **THEN** the system uses `.#prod` as the target

#### Scenario: CLI mounts override config mounts
- **WHEN** `.epi/config.toml` contains `mounts = ["/home/user/a"]`
- **AND** the user runs `epi launch --mount /home/user/b`
- **THEN** the system uses `["/home/user/b"]` as the mount list (config mounts are NOT merged)

#### Scenario: CLI disk-size overrides config disk_size
- **WHEN** `.epi/config.toml` contains `disk_size = "80G"`
- **AND** the user runs `epi launch --disk-size 20G`
- **THEN** the system uses `20G` as the disk size

#### Scenario: CLI cpus overrides config cpus
- **WHEN** `.epi/config.toml` contains `cpus = 2`
- **AND** the user runs `epi launch --cpus 8`
- **THEN** the system uses 8 as the CPU count

#### Scenario: CLI memory overrides config memory
- **WHEN** `.epi/config.toml` contains `memory = 2048`
- **AND** the user runs `epi launch --memory 8192`
- **THEN** the system uses 8192 MiB as the memory size
