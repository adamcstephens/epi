## Purpose
Define the manual-test NixOS configuration that the flake exposes so developers can validate it locally without switching the host system.

## Requirements

### Requirement: Manual-test configuration is exposed by the flake
The `flake.nix` outputs MUST include `nixosConfigurations.manual-test` so the configuration is reachable from standard Nix tools.

#### Scenario: Manual-test configuration is addressable
- **WHEN** a developer evaluates `nix flake show` or an equivalent inspection command for this repository
- **THEN** the output contains `nixosConfigurations.manual-test`
- **AND** the attribute resolves to a valid NixOS system configuration derivation
- **AND** the configuration references the dedicated manual-test module without leaking other host-specific wiring.

### Requirement: Manual-test configuration supports a local build path
The manual-test host MUST remain buildable via a non-destructive local command so developers can validate the configuration at will.

#### Scenario: Manual-test configuration builds locally
- **WHEN** a developer runs `nix build .#nixosConfigurations.manual-test.config.system.build.toplevel`
- **THEN** Nix evaluates the manual-test derivation without performing a system switch
- **AND** the build succeeds, proving the configuration wiring and module inputs remain valid for manual testing
- **AND** the resulting path can be referenced by follow-up `nixos-rebuild` or virtualization flows if needed.

### Requirement: Repository documents the manual test workflow
The repository documentation MUST describe how to run and judge the manual-test configuration so the workflow stays repeatable.

#### Scenario: Developer follows manual test instructions
- **WHEN** a developer reads the manual-testing section in the docs
- **THEN** the instructions include the canonical build command for `nixosConfigurations.manual-test`
- **AND** the instructions list expected success signals plus basic failure triage guidance (e.g., verifying derivation evaluation or checking module wiring)
- **AND** the documentation references the manual-test configuration name so future contributors can find the correct flake target.
