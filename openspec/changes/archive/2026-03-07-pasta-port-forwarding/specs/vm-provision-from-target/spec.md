## MODIFIED Requirements

### Requirement: Up returns actionable stage-specific errors
When provisioning fails, `epi up` MUST return an error message that identifies the failure stage and the relevant context.

#### Scenario: Target evaluation fails
- **WHEN** target evaluation fails for `epi up dev-a --target .#dev-a`
- **THEN** the command exits non-zero
- **AND** the error states that target resolution failed
- **AND** the error includes the failing target string

#### Scenario: VM launch fails
- **WHEN** cloud-hypervisor returns a non-zero exit for `epi up dev-a --target .#dev-a`
- **THEN** the command exits non-zero
- **AND** the error states that VM launch failed
- **AND** the error includes the cloud-hypervisor exit status

#### Scenario: pasta binary is missing
- **WHEN** the pasta binary is not found on PATH and `EPI_PASTA_BIN` is not set
- **THEN** `epi up` exits non-zero
- **AND** the error states that pasta was not found
- **AND** the error suggests installing the `passt` package or setting `EPI_PASTA_BIN`

#### Scenario: pasta socket is unavailable
- **WHEN** pasta is started but its vhost-user socket does not become available within the timeout
- **THEN** `epi up` exits non-zero
- **AND** the error states that the pasta socket did not become ready
- **AND** cloud-hypervisor is not started
