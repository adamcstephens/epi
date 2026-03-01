## ADDED Requirements

### Requirement: Up command creates or starts an instance from a target
The CLI SHALL provide an `up` command that accepts an optional positional instance name and a required `--target <flake#config>` option. If the instance name is omitted, the CLI MUST use `default` as the instance name.

#### Scenario: Explicit instance name provided
- **WHEN** a user runs `epi up dev-a --target .#dev-a`
- **THEN** the CLI resolves instance name `dev-a`
- **AND** the CLI resolves target `.#dev-a`

#### Scenario: Instance name omitted
- **WHEN** a user runs `epi up --target github:org/repo#dev`
- **THEN** the CLI resolves instance name `default`
- **AND** the CLI resolves target `github:org/repo#dev`

### Requirement: Target value follows flake#config syntax
The CLI SHALL treat `--target` as a single string value in `<flake-ref>#<config-name>` form and MUST reject malformed values with actionable errors.

#### Scenario: Missing separator
- **WHEN** a user runs `epi up dev-a --target .`
- **THEN** the CLI exits non-zero
- **AND** the error states that `--target` must use `<flake-ref>#<config-name>`

#### Scenario: Missing config name
- **WHEN** a user runs `epi up dev-a --target .#`
- **THEN** the CLI exits non-zero
- **AND** the error states that both flake reference and config name are required

### Requirement: Lifecycle commands operate on instance identity
The CLI SHALL treat lifecycle commands as operating on instance identity, not on target identity. The commands `down`, `rebuild`, `ssh`, and `logs` SHALL accept an optional positional instance name and MUST default to `default` when omitted.

#### Scenario: Explicit lifecycle target
- **WHEN** a user runs `epi down dev-a`
- **THEN** the CLI selects instance `dev-a` for shutdown

#### Scenario: Implicit default lifecycle target
- **WHEN** a user runs `epi ssh`
- **THEN** the CLI selects instance `default`

### Requirement: Missing default instance returns clear guidance
If a lifecycle command is invoked without an instance name and `default` does not exist, the CLI MUST fail with a clear message explaining how to create `default` or specify another instance.

#### Scenario: Default missing on lifecycle command
- **WHEN** a user runs `epi status` and no `default` instance exists
- **THEN** the CLI exits non-zero
- **AND** the error message mentions `default` was not found
- **AND** the error message suggests running `epi up --target <flake#config>` or passing an instance name

### Requirement: CLI exposes instance inventory
The CLI SHALL provide a `list` command that outputs known instance names and their associated targets.

#### Scenario: Multiple instances exist
- **WHEN** a user runs `epi list` with `default`, `dev-a`, and `qa-1` defined
- **THEN** the output includes each instance name
- **AND** the output includes the stored target for each instance
