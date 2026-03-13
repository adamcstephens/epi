### Requirement: Deterministic MAC address per instance
The system SHALL generate a deterministic MAC address from the instance name and pass it to cloud-hypervisor. The MAC MUST use the locally administered prefix (`02:` first octet) and MUST be identical across stop/start cycles for the same instance name.

#### Scenario: MAC is stable across restarts
- **WHEN** a VM instance is stopped and started again
- **THEN** the VM SHALL have the same MAC address as the original launch

#### Scenario: Different instances get different MACs
- **WHEN** two VM instances are launched with different names
- **THEN** they SHALL have different MAC addresses

### Requirement: SSH works after stop/start
The system SHALL maintain SSH connectivity after a stop/start cycle without requiring the user to re-provision or take any manual action.

#### Scenario: SSH after stop and start
- **WHEN** a running VM is stopped and then started
- **THEN** SSH connections to the new port SHALL succeed
