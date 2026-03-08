## ADDED Requirements

### Requirement: Start command resumes an existing stopped instance
The CLI SHALL provide a `start` command that accepts an optional positional instance name. If the instance name is omitted, the CLI MUST use `default`. The command MUST look up the stored target from the instance store and relaunch the VM using that target. The command MUST NOT require a `--target` flag.

#### Scenario: Start an existing stopped instance
- **WHEN** a user runs `epi start dev-a` and instance `dev-a` exists in the store but is not running
- **THEN** the CLI relaunches the VM using the stored target for `dev-a`
- **AND** the CLI prints output indicating the instance was started

#### Scenario: Start default instance when name omitted
- **WHEN** a user runs `epi start` and instance `default` exists in the store but is not running
- **THEN** the CLI relaunches the `default` VM using its stored target

### Requirement: Start fails with guidance when instance does not exist
If `start` is invoked for an instance that does not exist in the store, the CLI MUST exit non-zero with an error message that explains the instance was not found and directs the user to `epi launch` to create it.

#### Scenario: Instance not found
- **WHEN** a user runs `epi start unknown-vm` and no instance named `unknown-vm` exists
- **THEN** the CLI exits non-zero
- **AND** the error message states the instance was not found
- **AND** the error message suggests using `epi launch` to create a new instance

### Requirement: Start is idempotent for already-running instances
If the named instance is already running, `start` MUST print a notice that the instance is already running and exit zero without re-provisioning.

#### Scenario: Instance already running
- **WHEN** a user runs `epi start dev-a` and instance `dev-a` is already running
- **THEN** the CLI exits zero
- **AND** the CLI prints a message indicating the instance is already running

### Requirement: Start supports console attachment
The `start` command SHALL support a `--console` flag that, when set, attaches to the instance serial console immediately after the instance is started.

#### Scenario: Console attached after start
- **WHEN** a user runs `epi start dev-a --console`
- **THEN** the CLI starts the instance and then attaches to its serial console
