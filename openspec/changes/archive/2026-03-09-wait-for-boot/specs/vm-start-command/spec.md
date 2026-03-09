## ADDED Requirements

### Requirement: Start generates SSH key and waits for SSH
The `start` command SHALL generate an SSH keypair and wait for SSH connectivity by default, using the same logic as `launch`. The `--no-wait` and `--wait-timeout` flags SHALL be accepted.

#### Scenario: Start waits for SSH by default
- **WHEN** a user runs `epi start dev-a` and instance `dev-a` exists but is not running
- **THEN** the CLI relaunches the VM, generates an SSH key, and waits for SSH connectivity
- **AND** the command exits zero when SSH is reachable

#### Scenario: Start with --no-wait skips SSH polling
- **WHEN** a user runs `epi start dev-a --no-wait`
- **THEN** the CLI relaunches the VM and returns after the VM process is verified running
- **AND** no SSH polling is performed

#### Scenario: Start with --wait-timeout configures wait duration
- **WHEN** a user runs `epi start dev-a --wait-timeout 30`
- **THEN** the SSH polling phase uses a 30-second timeout
