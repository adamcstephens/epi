## Purpose
Define how the CLI persists and reconciles VM runtime metadata so status, lock diagnostics, and console workflows remain accurate.

## Requirements

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
- **WHEN** runtime metadata for `dev-a` contains a PID that is still alive
- **THEN** startup reconciliation keeps `dev-a` runtime metadata as running
- **AND** later commands can use that metadata for status and console attachment

### Requirement: Lock conflicts include owner-aware diagnostics
If VM launch fails due to an exclusive disk-image lock, the CLI MUST report conflict diagnostics using reconciled runtime metadata.

#### Scenario: Lock held by tracked running instance
- **WHEN** `epi up qa-1 --target .#qa` fails because the launch disk is write-locked by a running tracked VM
- **THEN** the command exits non-zero
- **AND** the error states that another running VM already holds the disk lock
- **AND** the error includes the owning instance name and PID when available
- **AND** the error suggests stopping that instance before retrying

#### Scenario: Lock conflict with unknown owner
- **WHEN** `epi up qa-1 --target .#qa` fails because the launch disk is write-locked and no tracked running owner matches
- **THEN** the command exits non-zero
- **AND** the error states that the disk image is already locked by another process
- **AND** the error includes the disk image path
- **AND** the error suggests checking for external cloud-hypervisor processes
