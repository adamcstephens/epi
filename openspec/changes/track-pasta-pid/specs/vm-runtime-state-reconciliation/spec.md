## MODIFIED Requirements

### Requirement: CLI tracks runtime metadata for launched VMs
The CLI SHALL persist per-instance runtime metadata after successful VM start, including the hypervisor PID, the pasta PID, and lock-relevant launch context.

#### Scenario: Runtime metadata is stored on successful launch
- **WHEN** `epi up dev-a --target .#dev-a` launches successfully
- **THEN** the CLI stores runtime metadata for `dev-a`
- **AND** the metadata includes the launched hypervisor PID
- **AND** the metadata includes the pasta PID
- **AND** the metadata includes lock-relevant launch context needed for conflict diagnostics

### Requirement: CLI reconciles runtime metadata at startup
At command startup, the CLI MUST run a fast reconciliation pass over tracked runtime metadata before command-specific execution.

#### Scenario: Stale runtime entry is cleared and pasta is terminated
- **WHEN** runtime metadata for `dev-a` contains a hypervisor PID that no longer exists
- **AND** runtime metadata for `dev-a` contains a pasta PID
- **THEN** startup reconciliation sends SIGTERM to the pasta process (best-effort)
- **AND** startup reconciliation marks `dev-a` as not running
- **AND** stale runtime metadata is cleared

#### Scenario: Active runtime entry remains available
- **WHEN** runtime metadata for `dev-a` contains a hypervisor PID that is still alive
- **THEN** startup reconciliation keeps `dev-a` runtime metadata as running
- **AND** later commands can use that metadata for status and console attachment
