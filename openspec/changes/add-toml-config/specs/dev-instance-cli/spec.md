## MODIFIED Requirements

### Requirement: Launch command creates or starts an instance from a target
The CLI SHALL provide a `launch` command that accepts an optional positional instance name and an optional `--target <flake#config>` option. If the instance name is omitted, the CLI MUST use `default` as the instance name. If `--target` is omitted, the CLI SHALL look for a `target` value in the project config file (`.epi/config.toml`). If neither CLI nor config provides a target, the CLI MUST exit non-zero with an error message explaining both ways to provide a target. The command SHALL accept `--no-wait` to skip SSH polling and `--wait-timeout` to configure the SSH wait duration.

#### Scenario: Explicit instance name provided
- **WHEN** a user runs `epi launch dev-a --target .#dev-a`
- **THEN** the CLI resolves instance name `dev-a`
- **AND** the CLI resolves target `.#dev-a`

#### Scenario: Instance name omitted
- **WHEN** a user runs `epi launch --target github:org/repo#dev`
- **THEN** the CLI resolves instance name `default`
- **AND** the CLI resolves target `github:org/repo#dev`

#### Scenario: --no-wait flag skips SSH polling
- **WHEN** a user runs `epi launch dev-a --target .#dev-a --no-wait`
- **THEN** the command returns after the VM process is verified running
- **AND** no SSH polling is performed

#### Scenario: --wait-timeout configures wait duration
- **WHEN** a user runs `epi launch --target .#dev-a --wait-timeout 60`
- **THEN** the SSH polling phase uses a 60-second timeout instead of the default

#### Scenario: Target from config file when --target omitted
- **WHEN** `.epi/config.toml` contains `target = ".#dev"`
- **AND** a user runs `epi launch` without `--target`
- **THEN** the CLI resolves target `.#dev`

#### Scenario: No target from CLI or config
- **WHEN** no `.epi/config.toml` exists or it has no `target` key
- **AND** a user runs `epi launch` without `--target`
- **THEN** the CLI exits non-zero
- **AND** the error message explains that `--target` is required or a target can be set in `.epi/config.toml`
