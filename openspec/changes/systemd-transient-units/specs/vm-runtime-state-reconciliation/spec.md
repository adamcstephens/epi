## MODIFIED Requirements

### Requirement: CLI tracks runtime metadata for launched VMs
The CLI SHALL persist per-instance runtime metadata after successful VM start, including the systemd session ID (`unit_id`), serial console socket path, disk path, forwarded SSH host port, and SSH key path. PID fields are no longer stored; process liveness is determined by constructing the systemd unit name from the escaped instance name and `unit_id`, then querying systemd unit status.

#### Scenario: Runtime metadata is stored on successful launch
- **WHEN** `epi up dev-a --target .#dev-a` launches successfully
- **THEN** the CLI stores runtime metadata for `dev-a`
- **AND** the metadata includes the `unit_id` (random session ID for this launch)
- **AND** the metadata includes the serial console socket path
- **AND** the metadata includes the disk path
- **AND** the metadata includes the host TCP port forwarded to VM port 22
- **AND** the metadata does not include PIDs

## REMOVED Requirements

### Requirement: CLI reconciles runtime metadata at startup
**Reason**: Systemd tracks process liveness natively via unit status. Stale PID cleanup is unnecessary because PIDs are no longer stored. Serial socket cleanup happens lazily at launch time.
**Migration**: Remove all `reconcile_runtime()` calls from command handlers. Liveness checks use `systemctl --user is-active epi-<instance>-vm.scope` instead.
