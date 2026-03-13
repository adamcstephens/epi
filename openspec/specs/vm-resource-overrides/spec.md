## ADDED Requirements

### Requirement: Launch accepts --cpus flag to override descriptor CPU count
The `launch` command SHALL accept an optional `--cpus <N>` flag where N is a positive integer. When provided, this value SHALL override the target descriptor's `cpus` value for the launched VM. When omitted, the system SHALL use the config value if set, otherwise the descriptor's value.

#### Scenario: --cpus overrides descriptor default
- **WHEN** a user runs `epi launch --cpus 4`
- **AND** the target descriptor specifies `cpus: 1`
- **THEN** the VM is launched with 4 CPUs

#### Scenario: --cpus overrides config value
- **WHEN** `.epi/config.toml` contains `cpus = 2`
- **AND** a user runs `epi launch --cpus 8`
- **THEN** the VM is launched with 8 CPUs

#### Scenario: --cpus omitted uses config then descriptor
- **WHEN** a user runs `epi launch` without `--cpus`
- **AND** no config sets `cpus`
- **AND** the target descriptor specifies `cpus: 2`
- **THEN** the VM is launched with 2 CPUs

### Requirement: Launch accepts --memory flag to override descriptor memory
The `launch` command SHALL accept an optional `--memory <MIB>` flag where MIB is a positive integer representing memory in mebibytes. When provided, this value SHALL override the target descriptor's `memory_mib` value for the launched VM. When omitted, the system SHALL use the config value if set, otherwise the descriptor's value.

#### Scenario: --memory overrides descriptor default
- **WHEN** a user runs `epi launch --memory 4096`
- **AND** the target descriptor specifies `memory_mib: 1024`
- **THEN** the VM is launched with 4096 MiB of memory

#### Scenario: --memory overrides config value
- **WHEN** `.epi/config.toml` contains `memory = 2048`
- **AND** a user runs `epi launch --memory 8192`
- **THEN** the VM is launched with 8192 MiB of memory

#### Scenario: --memory omitted uses config then descriptor
- **WHEN** a user runs `epi launch` without `--memory`
- **AND** no config sets `memory`
- **AND** the target descriptor specifies `memory_mib: 1024`
- **THEN** the VM is launched with 1024 MiB of memory

### Requirement: Resource overrides follow four-tier precedence
CPU and memory values SHALL be resolved with the following precedence (highest to lowest): CLI flag > project config > user config > target descriptor default.

#### Scenario: Config cpus overrides descriptor
- **WHEN** `.epi/config.toml` contains `cpus = 4`
- **AND** no `--cpus` CLI flag is provided
- **AND** the target descriptor specifies `cpus: 1`
- **THEN** the VM is launched with 4 CPUs

#### Scenario: User config provides default when project config omits
- **WHEN** user config contains `cpus = 2`
- **AND** project config does not set `cpus`
- **AND** no `--cpus` CLI flag is provided
- **AND** the target descriptor specifies `cpus: 1`
- **THEN** the VM is launched with 2 CPUs
