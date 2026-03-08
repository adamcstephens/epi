## MODIFIED Requirements

### Requirement: Manual-test VM has network connectivity

The manual-test NixOS configuration MUST include networking support with DHCP on the virtio-net interface so the VM is reachable from the host. The network connectivity SHALL be provided by pasta userspace networking rather than host-level TAP interfaces.

#### Scenario: VM obtains IP address via DHCP

- **WHEN** the manual-test VM boots with a pasta-backed virtio-net network device attached
- **THEN** the VM obtains an IP address via DHCP on the virtio-net interface
- **AND** the host can reach the VM at that IP address

## ADDED Requirements

### Requirement: Manual-test VM grows its root partition and filesystem on boot

The manual-test NixOS configuration MUST set `boot.growPartition = true` and `fileSystems."/".autoResize = true` so that the root partition is expanded to fill the available disk and the ext4 filesystem is resized to fill the partition on each boot where growth is needed.

#### Scenario: Root partition grows after disk resize

- **WHEN** the manual-test VM boots after its disk overlay was enlarged by `qemu-img resize`
- **THEN** `growpart` runs in early boot and extends the root partition to fill the disk
- **AND** the ext4 filesystem is resized to fill the enlarged partition
- **AND** the full disk capacity is available to the running system

#### Scenario: No-op when partition already fills disk

- **WHEN** the manual-test VM boots and the root partition already fills the disk
- **THEN** `growpart` exits successfully without modifying the partition table
- **AND** `resize2fs` exits successfully without modifying the filesystem
