### Requirement: User config file discovery
The system SHALL discover the user config file using the following precedence:
1. `EPI_CONFIG_FILE` environment variable (explicit path)
2. `XDG_CONFIG_HOME/epi/config.toml` (if `XDG_CONFIG_HOME` is set)
3. `HOME/.config/epi/config.toml` (default fallback)

#### Scenario: EPI_CONFIG_FILE set to existing file
- **WHEN** `EPI_CONFIG_FILE` is set to a path that exists
- **THEN** the system SHALL load user config from that path

#### Scenario: EPI_CONFIG_FILE set to nonexistent file
- **WHEN** `EPI_CONFIG_FILE` is set to a path that does not exist
- **THEN** the system SHALL return an error indicating the file was not found

#### Scenario: XDG_CONFIG_HOME set
- **WHEN** `EPI_CONFIG_FILE` is not set and `XDG_CONFIG_HOME` is set
- **THEN** the system SHALL look for config at `XDG_CONFIG_HOME/epi/config.toml`

#### Scenario: Default config path
- **WHEN** neither `EPI_CONFIG_FILE` nor `XDG_CONFIG_HOME` is set
- **THEN** the system SHALL look for config at `HOME/.config/epi/config.toml`

#### Scenario: No user config file exists
- **WHEN** no user config file is found at the discovered path
- **THEN** the system SHALL proceed with an empty user config (no error)

### Requirement: Three-tier config merge precedence
The system SHALL merge configuration from three sources with the following precedence (highest to lowest):
1. CLI arguments
2. Project config (`.epi/config.toml`)
3. User config

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
