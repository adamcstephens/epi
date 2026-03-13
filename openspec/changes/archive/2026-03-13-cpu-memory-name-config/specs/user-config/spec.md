## MODIFIED Requirements

### Requirement: Three-tier config merge precedence
The system SHALL merge configuration from three sources with the following precedence (highest to lowest):
1. CLI arguments
2. Project config (`.epi/config.toml`)
3. User config

This applies to all config keys: `target`, `mounts`, `disk_size`, `cpus`, `memory`, and `default_name`.

#### Scenario: CLI arg overrides project and user config
- **WHEN** a value is specified via CLI arg, project config, and user config
- **THEN** the CLI arg value SHALL be used

#### Scenario: Project config overrides user config
- **WHEN** a value is specified in both project config and user config but not via CLI
- **THEN** the project config value SHALL be used

#### Scenario: User config provides defaults
- **WHEN** a value is specified only in user config
- **THEN** the user config value SHALL be used

#### Scenario: No value specified anywhere
- **WHEN** a required value (e.g., target) is not specified in any source
- **THEN** the system SHALL return an error

#### Scenario: User config cpus used when project config omits
- **WHEN** user config contains `cpus = 4`
- **AND** project config does not set `cpus`
- **AND** no `--cpus` CLI flag is provided
- **THEN** the system uses 4 as the CPU count

#### Scenario: User config default_name used when project config omits
- **WHEN** user config contains `default_name = "myvm"`
- **AND** project config does not set `default_name`
- **THEN** the system uses `myvm` as the default instance name
