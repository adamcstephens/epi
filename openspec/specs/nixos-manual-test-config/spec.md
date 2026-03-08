## Purpose
Define the manual-test NixOS configuration that the flake exposes so developers can validate it locally without switching the host system.

## Requirements

### Requirement: Manual-test configuration is exposed by the flake
The `flake.nix` outputs MUST include `nixosConfigurations.manual-test` so the configuration is reachable from standard Nix tools. The manual-test module MUST enable cloud-init with the NoCloud datasource so user provisioning happens at runtime.

#### Scenario: Manual-test configuration is addressable
- **WHEN** a developer evaluates `nix flake show` or an equivalent inspection command for this repository
- **THEN** the output contains `nixosConfigurations.manual-test`
- **AND** the attribute resolves to a valid NixOS system configuration derivation
- **AND** the configuration references the dedicated manual-test module without leaking other host-specific wiring.

### Requirement: Manual-test configuration supports a local build path
The manual-test host MUST remain buildable via a non-destructive local command so developers can validate the configuration at will, and the built outputs MUST support coherent VM launch artifacts for `epi up`.

#### Scenario: Manual-test configuration builds locally
- **WHEN** a developer runs `nix build .#nixosConfigurations.manual-test.config.system.build.toplevel`
- **THEN** Nix evaluates the manual-test derivation without performing a system switch
- **AND** the build succeeds, proving the configuration wiring and module inputs remain valid for manual testing
- **AND** the resulting outputs can be used as a coherent source for follow-up virtualization flows

### Requirement: Repository documents the manual test workflow
The repository documentation MUST describe how to run and judge the manual-test configuration so the workflow stays repeatable, including how `epi up` consumes target-built launch artifacts.

#### Scenario: Developer follows manual test instructions
- **WHEN** a developer reads the manual-testing section in the docs
- **THEN** the instructions include the canonical build command for `nixosConfigurations.manual-test`
- **AND** the instructions describe that `epi up --target .#manual-test` expects kernel/initrd/disk to come from coherent target outputs
- **AND** the documentation references the manual-test configuration name so future contributors can find the correct flake target

### Requirement: Manual-test VM enables cloud-init
The manual-test NixOS configuration MUST enable `services.cloud-init` so that user provisioning data from the NoCloud seed ISO is applied at boot.

#### Scenario: cloud-init runs on first boot
- **WHEN** the manual-test VM boots with a `cidata`-labeled ISO attached
- **THEN** cloud-init detects the NoCloud datasource
- **AND** cloud-init applies the `user-data` configuration (user creation, SSH keys, sudo)

### Requirement: Manual-test VM has network connectivity
The manual-test NixOS configuration MUST include networking support with DHCP on the virtio-net interface so the VM is reachable from the host. The network connectivity SHALL be provided by pasta userspace networking rather than host-level TAP interfaces.

#### Scenario: VM obtains IP address via DHCP
- **WHEN** the manual-test VM boots with a pasta-backed virtio-net network device attached
- **THEN** the VM obtains an IP address via DHCP on the virtio-net interface
- **AND** the host can reach the VM at that IP address

### Requirement: Manual-test VM runs SSH server
The manual-test NixOS configuration MUST enable the OpenSSH server so remote access is available.

#### Scenario: SSH server listening after boot
- **WHEN** the manual-test VM has finished booting
- **THEN** the OpenSSH server is running and listening on port 22
- **AND** password authentication is disabled
- **AND** only key-based authentication is accepted

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

### Requirement: Manual-test VM includes virtio-net kernel module
The manual-test NixOS configuration MUST include the `virtio_net` kernel module in the initrd so the network device is available at boot.

#### Scenario: Network device available in initrd
- **WHEN** the manual-test VM boots
- **THEN** the `virtio_net` module is loaded during initrd
- **AND** the virtio-net network interface is available for DHCP configuration
