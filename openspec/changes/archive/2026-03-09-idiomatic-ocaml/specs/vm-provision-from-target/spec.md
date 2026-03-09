## MODIFIED Requirements

### Requirement: Up provisions a VM from the requested target
The `epi launch` command SHALL evaluate the provided `--target <flake-ref>#<config-name>` and SHALL attempt to provision and start a cloud-hypervisor VM for the resolved instance using coherent launch inputs produced by that target evaluation. The VM SHALL be launched with passt-backed networking instead of TAP-based networking. When a valid descriptor cache exists for the target and all artifact paths are present on disk, the CLI SHALL skip nix eval and nix build and use the cached descriptor directly. When relaunching over a stale instance, the CLI SHALL terminate any tracked systemd units from the prior runtime before starting a new one. The target resolver (whether built-in `nix eval --json` or custom via `EPI_TARGET_RESOLVER_CMD`) MUST produce JSON output containing the descriptor fields.

#### Scenario: Named instance is provisioned
- **WHEN** a user runs `epi launch dev-a --target .#dev-a`
- **THEN** the CLI evaluates target `.#dev-a` (or uses a valid cache)
- **AND** the CLI invokes cloud-hypervisor using the resolved VM launch inputs with passt networking
- **AND** the CLI reports provisioning success for instance `dev-a`

#### Scenario: Default instance is provisioned
- **WHEN** a user runs `epi launch --target github:org/repo#dev`
- **THEN** the CLI resolves instance name `default`
- **AND** the CLI invokes cloud-hypervisor for the resolved target using coherent launch inputs from one evaluation result with passt networking
- **AND** the CLI reports provisioning success for instance `default`

#### Scenario: Stale systemd units are terminated before relaunch
- **WHEN** a user runs `epi launch dev-a --target .#dev-a`
- **AND** instance `dev-a` has a stale runtime entry with systemd units
- **THEN** the CLI stops the stale systemd units before launching the new VM
- **AND** the CLI successfully provisions the new instance

#### Scenario: Cached descriptor is used when valid
- **WHEN** a user runs `epi launch --target .#dev-a` and a valid descriptor cache exists with all paths on disk
- **THEN** the CLI skips nix eval
- **AND** the CLI invokes cloud-hypervisor using the cached descriptor

#### Scenario: Custom target resolver must output JSON
- **WHEN** `EPI_TARGET_RESOLVER_CMD` is set to a custom script
- **THEN** the script MUST output a JSON object with keys: `kernel`, `disk`, `initrd`, `cmdline`, `cpus`, `memory_mib`, `configuredUsers`
- **AND** the CLI SHALL parse the output as JSON using the same parser as `nix eval --json`
