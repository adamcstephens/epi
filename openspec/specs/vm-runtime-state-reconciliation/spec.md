## Purpose
Define how the CLI persists and queries VM runtime metadata so status, lock diagnostics, and console workflows remain accurate across commands.

## Requirements

### Requirement: CLI tracks a unit_id for each launched VM
After successful VM launch, the CLI SHALL persist a `unit_id` (8-character random lowercase hex) in the instance `runtime` file. The `unit_id` is used to construct all systemd unit names for that launch session and to query liveness via systemd.

#### Scenario: unit_id is stored on successful launch
- **WHEN** `epi launch dev-a --target .#dev-a` succeeds
- **THEN** the CLI stores a `runtime` file for `dev-a` containing `unit_id`, `serial_socket`, `disk`, and `ssh_port`

### Requirement: Systemd unit naming convention
All processes for an instance are grouped under a systemd slice and named using a consistent scheme derived from the instance name and `unit_id`.

The instance name is first escaped using `systemd-escape` to produce a systemd-safe string. The separator between `unit_id` and role is `_` (underscore), not `-`, to avoid creating phantom intermediate slice names.

Unit names follow this pattern:

```
epi-<escaped>_<unit_id>.slice                         (slice grouping all processes)
epi-<escaped>_<unit_id>_vm.service                    (cloud-hypervisor)
epi-<escaped>_<unit_id>_passt.service                 (passt networking)
epi-<escaped>_<unit_id>_virtiofsd_<N>.service         (virtiofsd, N=0,1,... per mount)
```

Example: instance `dev-a` with `unit_id=abc12345`:
- Escaped name: `dev\x2da` (from `systemd-escape dev-a`)
- Slice: `epi-dev\x2da_abc12345.slice`
- VM: `epi-dev\x2da_abc12345_vm.service`
- Passt: `epi-dev\x2da_abc12345_passt.service`

#### Scenario: unit_id uniqueness prevents collisions
- **WHEN** a previous launch's systemd units are still active but the runtime file was lost
- **THEN** a new launch generates a fresh `unit_id`
- **AND** the new units do not collide with any existing units from the prior session

#### Scenario: Hyphens in instance names are escaped
- **WHEN** an instance is named `dev-a`
- **THEN** the systemd escape of `dev-a` is `dev\x2da`
- **AND** the slice `epi-dev\x2da_<unit_id>.slice` is a direct child of `epi.slice`
- **AND** no phantom intermediate slices are created

### Requirement: Instance liveness is determined by systemd unit status
The CLI SHALL determine whether an instance is running by querying `systemctl --user is-active` on the VM service unit name (`epi-<escaped>_<unit_id>_vm.service`). No signal-0 checks or PID file inspection are performed.

#### Scenario: Running instance is detected
- **WHEN** the runtime file for `dev-a` contains a valid `unit_id`
- **AND** `systemctl --user is-active epi-<escaped>_<unit_id>_vm.service` returns exit 0
- **THEN** `dev-a` is considered running

#### Scenario: Stopped instance is detected
- **WHEN** the runtime file for `dev-a` contains a `unit_id`
- **AND** the corresponding VM service is not active (or does not exist)
- **THEN** `dev-a` is considered stopped

#### Scenario: Missing runtime means stopped
- **WHEN** no `runtime` file exists for `dev-a`
- **THEN** `dev-a` is considered stopped

### Requirement: Stopping an instance terminates all processes via the slice
The CLI SHALL stop an instance by running `systemctl --user stop epi-<escaped>_<unit_id>.slice`. This atomically terminates cloud-hypervisor, passt, and all virtiofsd processes.

#### Scenario: Stop cascades to all helper processes
- **WHEN** `epi stop dev-a` is invoked for a running instance
- **THEN** the CLI stops the instance slice
- **AND** all processes in the slice (VM, passt, virtiofsd) are terminated
- **AND** the `runtime` file is removed after successful stop

### Requirement: VM service cascades shutdown to helpers on unexpected exit
The VM systemd service has `ExecStopPost=` directives that stop each helper service (passt, virtiofsd) when cloud-hypervisor exits for any reason, including crashes and guest-initiated shutdown.

#### Scenario: Guest shutdown cleans up helpers
- **WHEN** the NixOS guest shuts down, causing cloud-hypervisor to exit
- **THEN** the VM service's `ExecStopPost` triggers
- **AND** all helper services in the slice are stopped

### Requirement: Lock conflicts include owner-aware diagnostics
If VM launch fails because the target disk is already held by another running instance, the CLI MUST report which instance holds the lock.

#### Scenario: Lock held by a tracked running instance
- **WHEN** `epi launch qa-1 --target .#qa` fails because the disk is write-locked by running instance `dev-a`
- **THEN** the command exits non-zero
- **AND** the error names `dev-a` as the owner
- **AND** the error includes `dev-a`'s `unit_id`
- **AND** the error suggests stopping `dev-a` before retrying

### Requirement: Stale runtime is cleared before relaunch
Before launching a new VM for an instance that has a stale runtime (unit no longer active), the CLI SHALL attempt to stop the old slice and clear the runtime file, then proceed with a fresh launch.

#### Scenario: Stale runtime is cleaned up on relaunch
- **WHEN** `epi launch dev-a --target .#dev-a` is invoked
- **AND** `dev-a` has a runtime file but the VM service is no longer active
- **THEN** the CLI attempts to stop the old slice
- **AND** clears the stale runtime file
- **AND** proceeds to provision a new VM session
