## ADDED Requirements

### Requirement: Flake Exposes Manual Test NixOS Configuration
The project flake MUST expose a `nixosConfigurations` output that includes a manual testing host configuration named `manual-test`.

#### Scenario: Manual-test configuration is addressable from flake outputs
- **WHEN** a developer evaluates flake outputs for this repository
- **THEN** `nixosConfigurations.manual-test` is present
- **AND** it resolves to a valid NixOS system configuration value

### Requirement: Manual-Test Configuration Is Buildable for Local Validation
The manual-test host configuration MUST support a non-destructive local build path for validation.

#### Scenario: Developer builds the manual-test system derivation
- **WHEN** a developer runs the documented build command for `nixosConfigurations.manual-test`
- **THEN** Nix evaluates and builds the system toplevel derivation without requiring system switch
- **AND** build success confirms configuration wiring is valid for manual testing

### Requirement: Repository Documents Manual Test Workflow
The repository MUST document how to run manual testing for the `manual-test` NixOS configuration.

#### Scenario: Developer follows documented manual test instructions
- **WHEN** a developer reads the repository's manual testing instructions
- **THEN** the instructions include the exact command for validating `nixosConfigurations.manual-test`
- **AND** the instructions describe expected success signals and basic failure triage context
