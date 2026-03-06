## MODIFIED Requirements

### Requirement: CLI tracks runtime metadata for launched VMs
The CLI SHALL persist per-instance runtime metadata after successful VM start, including the hypervisor PID, lock-relevant launch context, and the forwarded SSH host port.

#### Scenario: Runtime metadata is stored on successful launch
- **WHEN** `epi up dev-a --target .#dev-a` launches successfully
- **THEN** the CLI stores runtime metadata for `dev-a`
- **AND** the metadata includes the launched hypervisor PID
- **AND** the metadata includes lock-relevant launch context needed for conflict diagnostics
- **AND** the metadata includes the host TCP port forwarded to VM port 22

### Requirement: CLI reconciles runtime metadata at startup
At command startup, the CLI MUST run a fast reconciliation pass over tracked runtime metadata before command-specific execution.

#### Scenario: Stale runtime entry is cleared
- **WHEN** runtime metadata for `dev-a` contains a PID that no longer exists
- **THEN** startup reconciliation marks `dev-a` as not running
- **AND** stale runtime metadata that depends on that dead PID is cleared

#### Scenario: Active runtime entry remains available
- **WHEN** runtime metadata for `dev-a` contains a PID that is still alive
- **THEN** startup reconciliation keeps `dev-a` runtime metadata as running
- **AND** later commands can use that metadata for status and console attachment

#### Scenario: Runtime entry missing ssh_port field is tolerated
- **WHEN** runtime metadata for `dev-a` was written by an older version of epi that did not include `ssh_port`
- **THEN** startup reconciliation loads the entry successfully
- **AND** the SSH port is treated as unknown for that instance
