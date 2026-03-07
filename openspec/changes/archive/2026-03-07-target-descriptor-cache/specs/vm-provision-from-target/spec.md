## MODIFIED Requirements

### Requirement: Up provisions a VM from the requested target
The `epi up` command SHALL evaluate the provided `--target <flake-ref>#<config-name>` and SHALL attempt to provision and start a cloud-hypervisor VM for the resolved instance using coherent launch inputs produced by that target evaluation. The VM SHALL be launched with pasta-backed networking instead of TAP-based networking. When a valid descriptor cache exists for the target and all artifact paths are present on disk, the CLI SHALL skip nix eval and nix build and use the cached descriptor directly.

#### Scenario: Named instance is provisioned
- **WHEN** a user runs `epi up dev-a --target .#dev-a`
- **THEN** the CLI evaluates target `.#dev-a` (or uses a valid cache)
- **AND** the CLI invokes cloud-hypervisor using the resolved VM launch inputs with pasta networking
- **AND** the CLI reports provisioning success for instance `dev-a`

#### Scenario: Default instance is provisioned
- **WHEN** a user runs `epi up --target github:org/repo#dev`
- **THEN** the CLI resolves instance name `default`
- **AND** the CLI invokes cloud-hypervisor for the resolved target using coherent launch inputs from one evaluation result with pasta networking
- **AND** the CLI reports provisioning success for instance `default`

#### Scenario: Cached descriptor is used when valid
- **WHEN** a user runs `epi up --target .#dev-a` and a valid descriptor cache exists with all paths on disk
- **THEN** the CLI skips nix eval
- **AND** the CLI invokes cloud-hypervisor using the cached descriptor

## ADDED Requirements

### Requirement: Up accepts --rebuild to force re-evaluation
The `epi up` command SHALL accept a `--rebuild` flag that bypasses the descriptor cache, forces nix eval and nix build, and updates the cache with the fresh result before launching.

#### Scenario: --rebuild forces eval on cached target
- **WHEN** a user runs `epi up --target .#foo --rebuild`
- **THEN** the descriptor cache for `.#foo` is invalidated
- **AND** nix eval is run unconditionally
- **AND** the resolved descriptor is cached before VM launch
