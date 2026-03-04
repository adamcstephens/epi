## MODIFIED Requirements

### Requirement: Manual-test configuration is exposed by the flake
The `flake.nix` outputs MUST include `nixosConfigurations.manual-test` so the configuration is reachable from standard Nix tools. The manual-test module MUST enable cloud-init with the NoCloud datasource so user provisioning happens at runtime.

#### Scenario: Manual-test configuration is addressable
- **WHEN** a developer evaluates `nix flake show` or an equivalent inspection command for this repository
- **THEN** the output contains `nixosConfigurations.manual-test`
- **AND** the attribute resolves to a valid NixOS system configuration derivation
- **AND** the configuration references the dedicated manual-test module without leaking other host-specific wiring.

## ADDED Requirements

### Requirement: Manual-test VM enables cloud-init
The manual-test NixOS configuration MUST enable `services.cloud-init` so that user provisioning data from the NoCloud seed ISO is applied at boot.

#### Scenario: cloud-init runs on first boot
- **WHEN** the manual-test VM boots with a `cidata`-labeled ISO attached
- **THEN** cloud-init detects the NoCloud datasource
- **AND** cloud-init applies the `user-data` configuration (user creation, SSH keys, sudo)

### Requirement: Manual-test VM has network connectivity
The manual-test NixOS configuration MUST include networking support with DHCP on the virtio-net interface so the VM is reachable from the host.

#### Scenario: VM obtains IP address via DHCP
- **WHEN** the manual-test VM boots with a virtio-net network device attached
- **THEN** the VM obtains an IP address via DHCP on the virtio-net interface
- **AND** the host can reach the VM at that IP address

### Requirement: Manual-test VM runs SSH server
The manual-test NixOS configuration MUST enable the OpenSSH server so remote access is available.

#### Scenario: SSH server listening after boot
- **WHEN** the manual-test VM has finished booting
- **THEN** the OpenSSH server is running and listening on port 22
- **AND** password authentication is disabled
- **AND** only key-based authentication is accepted

### Requirement: Manual-test VM includes virtio-net kernel module
The manual-test NixOS configuration MUST include the `virtio_net` kernel module in the initrd so the network device is available at boot.

#### Scenario: Network device available in initrd
- **WHEN** the manual-test VM boots
- **THEN** the `virtio_net` module is loaded during initrd
- **AND** the virtio-net network interface is available for DHCP configuration
