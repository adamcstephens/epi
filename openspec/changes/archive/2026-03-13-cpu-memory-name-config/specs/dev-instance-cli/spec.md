## MODIFIED Requirements

### Requirement: Launch command creates or starts an instance from a target
The CLI SHALL provide a `launch` command that accepts an optional positional instance name and an optional `--target <flake#config>` option. If the instance name is omitted, the CLI MUST use the `default_name` from config, falling back to `default` if not configured. If `--target` is omitted, the CLI SHALL look for a `target` value in the project config file (`.epi/config.toml`). If neither CLI nor config provides a target, the CLI MUST exit non-zero with an error message explaining both ways to provide a target. The command SHALL accept `--no-wait` to skip SSH polling, `--wait-timeout` to configure the SSH wait duration, `--cpus` to override the descriptor CPU count, and `--memory` to override the descriptor memory size.

During launch, the CLI SHALL show step-based progress output on stderr: a spinner during provisioning with elapsed time, and a spinner during SSH wait with elapsed time. On completion, the CLI SHALL display a success message with the SSH port. When `--console` is active, the CLI SHALL skip spinners (to avoid corrupting raw terminal mode) and use plain text messages instead.

#### Scenario: Explicit instance name provided
- **WHEN** a user runs `epi launch dev-a --target .#dev-a`
- **THEN** the CLI resolves instance name `dev-a`
- **AND** the CLI resolves target `.#dev-a`

#### Scenario: Instance name omitted uses default_name from config
- **WHEN** `.epi/config.toml` contains `default_name = "dev"`
- **AND** a user runs `epi launch --target .#dev`
- **THEN** the CLI resolves instance name `dev`

#### Scenario: Instance name omitted with no default_name configured
- **WHEN** no config sets `default_name`
- **AND** a user runs `epi launch --target github:org/repo#dev`
- **THEN** the CLI resolves instance name `default`

#### Scenario: --cpus flag overrides descriptor
- **WHEN** a user runs `epi launch --cpus 4`
- **THEN** the VM is launched with 4 CPUs regardless of the descriptor value

#### Scenario: --memory flag overrides descriptor
- **WHEN** a user runs `epi launch --memory 4096`
- **THEN** the VM is launched with 4096 MiB of memory regardless of the descriptor value

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

#### Scenario: Progress spinners during launch
- **WHEN** a user runs `epi launch` in an interactive terminal
- **THEN** stderr shows a spinner during provisioning with elapsed time
- **AND** stderr shows a spinner during SSH wait with elapsed time
- **AND** on success, a "checkmark" prefixed message shows the instance is ready with the SSH port

#### Scenario: Plain progress with --console flag
- **WHEN** a user runs `epi launch --console`
- **THEN** the SSH wait in the background thread uses plain `eprintln!` messages instead of spinners

### Requirement: Lifecycle commands operate on instance identity
The CLI SHALL treat lifecycle commands as operating on instance identity, not on target identity. The commands `stop`, `rebuild`, `ssh`, `exec`, and `logs` SHALL accept an optional positional instance name and MUST use the `default_name` from config when omitted, falling back to `default` if not configured.

#### Scenario: Explicit lifecycle target
- **WHEN** a user runs `epi stop dev-a`
- **THEN** the CLI selects instance `dev-a` for shutdown

#### Scenario: Implicit default lifecycle target with default_name configured
- **WHEN** `.epi/config.toml` contains `default_name = "dev"`
- **AND** a user runs `epi ssh`
- **THEN** the CLI selects instance `dev`

#### Scenario: Implicit default lifecycle target without default_name
- **WHEN** no config sets `default_name`
- **AND** a user runs `epi ssh`
- **THEN** the CLI selects instance `default`

#### Scenario: Exec uses configured default instance
- **WHEN** `.epi/config.toml` contains `default_name = "dev"`
- **AND** a user runs `epi exec -- hostname`
- **THEN** the CLI selects instance `dev`
