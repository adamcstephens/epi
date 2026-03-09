## ADDED Requirements

### Requirement: CLI escapes instance names for systemd unit names
The CLI SHALL run `systemd-escape` on the instance name to produce a systemd-safe string before constructing unit names. This ensures names containing hyphens, dots, or other special characters do not produce invalid unit names or unintended slice hierarchies. The escaping is a bijection, guaranteeing that distinct instance names always produce distinct unit names.

#### Scenario: Instance name with hyphens is escaped
- **WHEN** `epi up dev-a --target .#dev-a` provisions successfully
- **THEN** the instance name `dev-a` is escaped via `systemd-escape`
- **AND** the resulting unit names use the escaped form in the instance portion

#### Scenario: Simple instance name passes through escaping unchanged
- **WHEN** `epi up myvm --target .#dev` provisions successfully
- **THEN** the instance name `myvm` is escaped via `systemd-escape`
- **AND** the escaped form is `myvm` (no transformation needed)

### Requirement: CLI generates a random session ID per launch to prevent unit name collisions
Each launch SHALL generate a short random hex identifier (session ID) that is included in all systemd unit names for that launch. The session ID SHALL be persisted in the runtime file as `unit_id`. This prevents `systemd-run` "Unit already exists" failures when re-launching an instance whose previous systemd units are still active (e.g., after state file corruption or crash).

#### Scenario: Each launch gets a unique session ID
- **WHEN** `epi up dev-a --target .#dev-a` provisions successfully
- **THEN** a random session ID is generated
- **AND** all unit names include the session ID
- **AND** the session ID is stored in the runtime file as `unit_id`

#### Scenario: Re-launch does not collide with orphaned units
- **WHEN** `epi up dev-a --target .#dev-a` is run and previous systemd units for `dev-a` are still active from a prior launch
- **THEN** the CLI attempts to stop the old slice using the old `unit_id` from the runtime file (best-effort)
- **AND** the CLI generates a fresh session ID for the new launch
- **AND** the new units do not collide with any remaining old units

### Requirement: CLI starts cloud-hypervisor as a transient systemd service
The CLI SHALL start cloud-hypervisor as a transient systemd user service (`systemd-run --user` without `--scope`) with `Type=exec`. This enables `ExecStopPost=` for cascading shutdown when the VM exits.

#### Scenario: Cloud-hypervisor is started as a transient service
- **WHEN** `epi up dev-a --target .#dev-a` provisions successfully
- **THEN** the cloud-hypervisor process runs inside a transient systemd user service named `epi-<escaped>-<id>-vm.service`
- **AND** the service is a member of the instance slice

### Requirement: CLI starts helper processes as systemd user scopes
The CLI SHALL start passt and virtiofsd as transient systemd user scopes (`systemd-run --user --scope`), grouped under the same instance slice as the VM service.

#### Scenario: Passt is started as a systemd scope
- **WHEN** `epi up dev-a --target .#dev-a` provisions successfully
- **THEN** the passt process runs inside a systemd user scope named `epi-<escaped>-<id>-passt.scope`
- **AND** the scope is a member of the instance slice

#### Scenario: Virtiofsd instances are started as systemd scopes
- **WHEN** `epi up dev-a --target .#dev-a --mount /home/user/src --mount /home/user/data` provisions successfully
- **THEN** each virtiofsd process runs inside a systemd user scope named `epi-<escaped>-<id>-virtiofsd-<index>.scope`
- **AND** each scope is a member of the instance slice

### Requirement: VM exit cascades to all helper processes via ExecStopPost
The VM transient service SHALL be configured with `ExecStopPost=` that stops the entire instance slice. When cloud-hypervisor exits for any reason (crash, guest-initiated shutdown, or explicit stop), systemd SHALL automatically stop the instance slice, terminating all helper processes. The `ExecStopPost` command SHALL use the NixOS absolute path `/run/current-system/sw/bin/systemctl` since `ExecStopPost=` does not inherit the user's `$PATH`.

#### Scenario: Guest shutdown cascades to helpers
- **WHEN** a user runs `shutdown` inside the guest VM
- **THEN** cloud-hypervisor exits
- **AND** systemd runs the `ExecStopPost` command on the VM service
- **AND** the entire instance slice is stopped
- **AND** passt and all virtiofsd processes are terminated

#### Scenario: VM crash cascades to helpers
- **WHEN** cloud-hypervisor crashes unexpectedly
- **THEN** systemd runs the `ExecStopPost` command on the VM service
- **AND** the entire instance slice is stopped
- **AND** passt and all virtiofsd processes are terminated

#### Scenario: Explicit stop cascades to helpers
- **WHEN** a user runs `epi down dev-a`
- **THEN** the CLI stops the instance slice
- **AND** cloud-hypervisor, passt, and all virtiofsd processes are terminated

### Requirement: CLI groups all instance processes under a shared slice
The CLI SHALL place all systemd units for a given instance launch under a single systemd slice named `epi-<escaped>-<id>.slice`, enabling atomic lifecycle operations on the entire process group.

#### Scenario: All processes share an instance slice
- **WHEN** `epi up dev-a --target .#dev-a --mount /home/user/src` provisions successfully
- **THEN** the VM service, passt scope, and virtiofsd scope are all members of the same `epi-<escaped>-<id>.slice`

### Requirement: CLI determines process liveness via systemd unit status
The CLI SHALL query `systemctl --user is-active <unit>` to determine whether a process is running, instead of sending signal 0 to a stored PID. The unit name is constructed from the escaped instance name and the `unit_id` stored in the runtime file.

#### Scenario: Running VM is detected as alive
- **WHEN** `epi status dev-a` is run and the VM service for `dev-a` is active
- **THEN** the CLI reports `dev-a` as running

#### Scenario: Stopped VM is detected as not running
- **WHEN** `epi status dev-a` is run and the VM service for `dev-a` is inactive
- **THEN** the CLI reports `dev-a` as not running

### Requirement: CLI stops instances by stopping the systemd slice
The CLI SHALL stop all processes for an instance by running `systemctl --user stop` on the instance slice, which terminates all units within the slice. The slice name is constructed from the escaped instance name and the stored `unit_id`.

#### Scenario: Down stops all instance processes atomically
- **WHEN** a user runs `epi down dev-a` and `dev-a` is running
- **THEN** the CLI stops the instance slice
- **AND** cloud-hypervisor, passt, and all virtiofsd processes for `dev-a` are terminated

#### Scenario: Down on already-stopped instance
- **WHEN** a user runs `epi down dev-a` and the VM service is inactive
- **THEN** the CLI reports that `dev-a` is not running

### Requirement: Transient units are collected after process exit
The CLI SHALL use the `--collect` flag with `systemd-run` so that transient units are automatically garbage-collected after the process exits, preventing dead unit accumulation.

#### Scenario: Unit is removed after process exits
- **WHEN** cloud-hypervisor exits (normally or abnormally)
- **THEN** the VM service unit is automatically removed by systemd

### Requirement: Process stdout and stderr are directed to log files
The CLI SHALL configure systemd units to write process stdout and stderr to instance-specific log files using systemd `StandardOutput` and `StandardError` properties.

#### Scenario: Cloud-hypervisor logs go to instance log files
- **WHEN** `epi up dev-a --target .#dev-a` provisions successfully
- **THEN** cloud-hypervisor stdout is written to the instance stdout log path
- **AND** cloud-hypervisor stderr is written to the instance stderr log path

### Requirement: CLI provides actionable error when user session is unavailable
The CLI SHALL detect when `systemd-run --user` fails due to an unavailable user session and report guidance to the user.

#### Scenario: systemd-run fails without user session
- **WHEN** `epi up dev-a --target .#dev-a` is run and `systemd-run --user` fails because no user session is active
- **THEN** the CLI exits non-zero
- **AND** the error suggests running `loginctl enable-linger` or starting a user session
