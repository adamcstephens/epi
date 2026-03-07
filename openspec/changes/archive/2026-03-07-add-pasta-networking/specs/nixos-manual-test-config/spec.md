## MODIFIED Requirements

### Requirement: Manual-test VM has network connectivity
The manual-test NixOS configuration MUST include networking support with DHCP on the virtio-net interface so the VM is reachable from the host. The network connectivity SHALL be provided by pasta userspace networking rather than host-level TAP interfaces.

#### Scenario: VM obtains IP address via DHCP
- **WHEN** the manual-test VM boots with a pasta-backed virtio-net network device attached
- **THEN** the VM obtains an IP address via DHCP on the virtio-net interface
- **AND** the host can reach the VM at that IP address
