## MODIFIED Requirements

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
