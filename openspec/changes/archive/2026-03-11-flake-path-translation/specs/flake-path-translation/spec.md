## ADDED Requirements

### Requirement: Translate shorthand target to canonical attrpath
The system SHALL translate a target of the form `<flake-ref>#<name>` to `<flake-ref>#nixosConfigurations.<name>` before resolution. If the config name already starts with `nixosConfigurations.`, the system SHALL NOT double-prefix.

#### Scenario: Shorthand target is translated
- **WHEN** user provides target `.#manual-test`
- **THEN** epi resolves against `.#nixosConfigurations.manual-test`

#### Scenario: Already-canonical target is not modified
- **WHEN** user provides target `.#nixosConfigurations.manual-test`
- **THEN** epi resolves against `.#nixosConfigurations.manual-test` (unchanged)

### Requirement: Eval check before resolution
The system SHALL run a lightweight eval check on the translated attrpath before full descriptor resolution. If the attrpath does not exist in the flake, the system SHALL return a user-friendly error message that includes the translated target path.

#### Scenario: Target exists
- **WHEN** user provides a valid target `.#dev`
- **THEN** epi proceeds with descriptor resolution normally

#### Scenario: Target does not exist
- **WHEN** user provides target `.#nonexistent`
- **THEN** epi reports an error like `target '.#nixosConfigurations.nonexistent' not found in flake` without proceeding to full resolution
