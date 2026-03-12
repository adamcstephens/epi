### Requirement: epi-init-hooks service runs guest hooks after network is available
The NixOS guest image SHALL include an `epi-init-hooks.service` systemd oneshot service that executes guest-init hooks after network connectivity is established. The service SHALL order itself after both `epi-init.service` and `network-online.target`, and SHALL want `network-online.target` to ensure the network wait mechanism is active. The service SHALL order itself before `multi-user.target` and SHALL be wanted by `multi-user.target`.

#### Scenario: hooks service starts after network and init
- **WHEN** a VM boots with guest hook scripts in the seed ISO
- **THEN** `epi-init-hooks.service` starts after `epi-init.service` completes and `network-online.target` is reached
- **AND** hook scripts have network connectivity

#### Scenario: SSH does not wait for hooks
- **WHEN** a VM boots with guest hook scripts
- **THEN** `sshd.service` starts after `epi-init.service` completes
- **AND** `sshd.service` does NOT depend on `epi-init-hooks.service`
- **AND** SSH is available before hooks finish executing

### Requirement: epi-init-hooks reads from the epidata ISO mount
The `epi-init-hooks.service` SHALL read the provisioned username from `/run/epi-init/epidata/epi.json` and file-based guest hooks from `/run/epi-init/epidata/hooks/`. If the epidata mount does not exist (epi-init exited early), the service SHALL exit cleanly. After executing all hooks, the service SHALL unmount the epidata ISO and clean up the mount point.

#### Scenario: hooks service reads username and hooks from mount
- **WHEN** `epi-init.service` has mounted the epidata ISO at `/run/epi-init/epidata`
- **AND** `epi-init-hooks.service` starts
- **THEN** the hooks service reads the username from `/run/epi-init/epidata/epi.json`
- **AND** reads scripts from `/run/epi-init/epidata/hooks/`
- **AND** executes hooks as that user
- **AND** unmounts the epidata ISO after hook execution completes

#### Scenario: hooks service skips when no epidata mount exists
- **WHEN** `epi-init.service` exited early (no epidata ISO found)
- **AND** `/run/epi-init/epidata/epi.json` does not exist
- **THEN** `epi-init-hooks.service` exits cleanly without running any hooks

### Requirement: epi-init-hooks enforces first-boot-only execution
The `epi-init-hooks.service` SHALL check for the guard file `/var/lib/epi-init-done` before executing hooks. If the guard file exists, the service SHALL skip all hook execution. After successfully running hooks (or if no hooks exist), the service SHALL create the guard file.

#### Scenario: hooks run on first boot
- **WHEN** a VM boots for the first time
- **AND** `/var/lib/epi-init-done` does not exist
- **THEN** the hooks service executes all guest hooks
- **AND** creates `/var/lib/epi-init-done` after completion

#### Scenario: hooks skip on subsequent boots
- **WHEN** a VM reboots (not first boot)
- **AND** `/var/lib/epi-init-done` exists
- **THEN** the hooks service exits without executing any hooks

### Requirement: epi-init-hooks executes hooks in correct order with failure tolerance
The `epi-init-hooks.service` SHALL execute seed ISO file-based hooks first (sorted by filename), then Nix-declared hooks (sorted by key name). If any hook exits non-zero, the service SHALL log the failure and continue with remaining hooks.

#### Scenario: execution order
- **WHEN** seed ISO contains file-based hooks
- **AND** Nix-declared guest-init hooks exist
- **THEN** file-based hooks execute first in filename order
- **AND** Nix-declared hooks execute after in key-name order

#### Scenario: hook failure is non-blocking
- **WHEN** a guest hook exits with code 1
- **THEN** the failure is logged to the console
- **AND** remaining hooks continue executing
- **AND** the VM continues booting normally
