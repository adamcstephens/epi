## ADDED Requirements

### Requirement: Up reports setup stage progress during provisioning
The `epi up` command SHALL emit concise, user-visible progress messages for major setup stages so users can distinguish active work from a stalled command.

#### Scenario: Target evaluation and build stage is visible
- **WHEN** a user runs `epi up --target .#manual-test` and target evaluation/build takes noticeable time
- **THEN** the CLI outputs a stage message indicating target evaluation/build has started
- **AND** the CLI outputs a stage transition or completion message before moving to launch preparation

#### Scenario: VM launch stage is visible
- **WHEN** a user runs `epi up dev-a --target .#dev-a` and provisioning proceeds to launch
- **THEN** the CLI outputs a stage message indicating VM launch has started
- **AND** the CLI outputs the existing success/failure outcome with stage-appropriate context

#### Scenario: Progress messages remain concise
- **WHEN** a user runs `epi up` for any valid target
- **THEN** progress output is limited to major stage transitions rather than verbose per-command logs
- **AND** the additional output remains human-readable without requiring verbose mode
