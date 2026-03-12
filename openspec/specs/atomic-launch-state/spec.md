### Requirement: CLI writes partial runtime before spawning processes

The `Vm_launch` module SHALL write a partial runtime to `state.json` — containing at minimum the `unit_id` — after generating the unit ID and before spawning any systemd processes (passt, virtiofsd, cloud-hypervisor). The target SHALL also be persisted at this point. This ensures the instance is discoverable and its systemd slice can be reconstructed for cleanup even if the CLI is interrupted during launch.

#### Scenario: State exists before first process spawn
- **WHEN** `epi launch dev-a --target .#dev-a` is run
- **AND** the CLI has generated a `unit_id` but has not yet spawned passt
- **THEN** `<state-root>/dev-a/state.json` EXISTS
- **AND** it contains a `target` field with value `.#dev-a`
- **AND** it contains a `runtime` object with a non-empty `unit_id` field

#### Scenario: Interrupted launch leaves discoverable state
- **WHEN** `epi launch dev-a --target .#dev-a` is killed after passt starts but before cloud-hypervisor starts
- **THEN** `<state-root>/dev-a/state.json` exists with a valid `unit_id`
- **AND** `epi list` includes `dev-a`
- **AND** `epi rm dev-a` can reconstruct the slice name from the `unit_id` and stop the orphaned processes

### Requirement: CLI updates runtime to full values after successful provision

After all processes are spawned and validated, the CLI SHALL overwrite the partial runtime in `state.json` with the complete runtime metadata (unit_id, serial_socket, disk, ssh_port, ssh_key_path). This is the existing behavior — the only change is that it overwrites a partial runtime rather than writing the first runtime.

#### Scenario: Successful launch has complete runtime
- **WHEN** `epi launch dev-a --target .#dev-a` completes successfully
- **THEN** `state.json` contains a `runtime` object with all fields populated: `unit_id`, `serial_socket`, `disk`, `ssh_port` (if applicable), and `ssh_key_path`

### Requirement: Cleanup works with partial runtime

The `epi rm` command SHALL successfully clean up instances that have a partial runtime (only `unit_id` populated). It SHALL reconstruct the slice name from `instance_name` and `unit_id`, attempt to stop the slice (tolerating the case where the slice does not exist), and remove the state directory.

#### Scenario: rm cleans up interrupted launch with running processes
- **WHEN** an instance `dev-a` has a partial runtime with `unit_id` and running systemd processes
- **AND** a user runs `epi rm dev-a`
- **THEN** the CLI stops the systemd slice `epi-<escaped>_<unit_id>.slice`
- **AND** the CLI removes the `dev-a` state directory

#### Scenario: rm cleans up interrupted launch with no running processes
- **WHEN** an instance `dev-a` has a partial runtime with `unit_id` but no running systemd processes
- **AND** a user runs `epi rm dev-a`
- **THEN** the CLI attempts to stop the slice (no-op since nothing is running)
- **AND** the CLI removes the `dev-a` state directory

### Requirement: Failed provision cleans up pre-spawn state

If `Vm_launch.provision` fails after writing the partial runtime, the caller SHALL clean up the state. On provision failure for a fresh launch (no pre-existing instance), the state directory SHALL be removed. On provision failure for a relaunch over an existing instance, the partial runtime SHALL be cleared but the state directory preserved.

#### Scenario: Fresh launch failure removes state
- **WHEN** `epi launch dev-a --target .#dev-a` fails during provisioning (e.g., passt fails to start)
- **AND** `dev-a` did not exist before this launch
- **THEN** the CLI stops the slice (best-effort) and removes the `dev-a` state directory
- **AND** `epi list` does not include `dev-a`

#### Scenario: Relaunch failure preserves existing state
- **WHEN** `dev-a` already exists with target `.#dev-a`
- **AND** `epi launch dev-a --target .#dev-a` fails during reprovisioning
- **THEN** the CLI stops the new slice (best-effort) and clears the new runtime from state
- **AND** `dev-a` still appears in `epi list` with its target preserved
