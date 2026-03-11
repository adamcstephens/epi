## MODIFIED Requirements

### Requirement: virtiofsd daemon lifecycle

The system SHALL start one `virtiofsd` daemon per mount path before launching cloud-hypervisor and SHALL track all their PIDs for cleanup. When the target descriptor's `overlayStore` field is `true`, the system SHALL additionally start a virtiofsd daemon for the host's `/nix` directory (tagged `nix-store`).

#### Scenario: One virtiofsd per mount path (overlayStore false)
- **WHEN** `--mount` is used N times during `epi launch` and the descriptor has `overlayStore: false`
- **THEN** N virtiofsd processes are started for user mounts, each with a unique vhost-user socket in the instance state directory
- **AND** the system waits for each socket to appear before launching cloud-hypervisor

#### Scenario: Extra virtiofsd for /nix (overlayStore true)
- **WHEN** `--mount` is used N times during `epi launch` and the descriptor has `overlayStore: true`
- **THEN** N+1 virtiofsd processes are started: one for `/nix` (tag `nix-store`) plus N for user mounts
- **AND** the system waits for each socket to appear before launching cloud-hypervisor

#### Scenario: virtiofsd stopped on instance down
- **WHEN** user runs `epi down` on an instance that was started with one or more `--mount` flags
- **THEN** all virtiofsd processes are terminated along with the VM and passt processes

#### Scenario: virtiofsd binary not found when required
- **WHEN** `epi launch` is run and virtiofsd is needed (either `--mount` flags provided or `overlayStore: true`) and `virtiofsd` is not on `$PATH` and `EPI_VIRTIOFSD_BIN` is not set
- **THEN** the system reports an error indicating virtiofsd is required and suggests setting `EPI_VIRTIOFSD_BIN`
