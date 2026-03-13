## ADDED Requirements

### Requirement: Config supports default_name key for instance name
The configuration file (both project and user) SHALL accept an optional `default_name` key whose value is a string. When present, this value SHALL be used as the default instance name for any command that accepts an optional positional instance name, replacing the hardcoded `"default"`.

#### Scenario: default_name in project config
- **WHEN** `.epi/config.toml` contains `default_name = "dev"`
- **AND** a user runs `epi launch` without a positional instance name
- **THEN** the system uses `dev` as the instance name

#### Scenario: default_name in user config
- **WHEN** user config contains `default_name = "myvm"`
- **AND** project config does not set `default_name`
- **AND** a user runs `epi ssh` without a positional instance name
- **THEN** the system uses `myvm` as the instance name

#### Scenario: No default_name configured
- **WHEN** neither project nor user config sets `default_name`
- **AND** a user runs `epi launch` without a positional instance name
- **THEN** the system uses `default` as the instance name

#### Scenario: Explicit instance name overrides default_name
- **WHEN** `.epi/config.toml` contains `default_name = "dev"`
- **AND** a user runs `epi launch prod`
- **THEN** the system uses `prod` as the instance name

### Requirement: default_name applies to all commands with optional instance name
The `default_name` config value SHALL apply to all commands that accept an optional positional instance name: `launch`, `start`, `stop`, `rebuild`, `ssh`, `exec`, `logs`, `status`, `rm`, and `cp`.

#### Scenario: default_name applies to stop command
- **WHEN** `.epi/config.toml` contains `default_name = "dev"`
- **AND** a user runs `epi stop` without a positional instance name
- **THEN** the system stops the instance named `dev`

#### Scenario: default_name applies to exec command
- **WHEN** `.epi/config.toml` contains `default_name = "dev"`
- **AND** a user runs `epi exec -- hostname` without a positional instance name
- **THEN** the system executes the command on the instance named `dev`
