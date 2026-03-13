## ADDED Requirements

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

## MODIFIED Requirements

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
