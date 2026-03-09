## MODIFIED Requirements

### Requirement: Lifecycle commands operate on instance identity
The CLI SHALL treat lifecycle commands as operating on instance identity, not on target identity. The commands `down`, `rebuild`, `ssh`, `exec`, and `logs` SHALL accept an optional positional instance name and MUST default to `default` when omitted.

#### Scenario: Explicit lifecycle target
- **WHEN** a user runs `epi down dev-a`
- **THEN** the CLI selects instance `dev-a` for shutdown

#### Scenario: Implicit default lifecycle target
- **WHEN** a user runs `epi ssh`
- **THEN** the CLI selects instance `default`

#### Scenario: Exec uses default instance
- **WHEN** a user runs `epi exec -- hostname`
- **THEN** the CLI selects instance `default`
