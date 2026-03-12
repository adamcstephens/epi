## Context

Today, `epi launch` follows a create-then-record pattern: it spawns systemd processes (passt, virtiofsd, cloud-hypervisor) via `Vm_launch.provision`, and only writes `state.json` after provisioning succeeds (`Instance_store.set_provisioned` in `epi.ml:194`). If the CLI is killed between process spawn and state write — or if any post-spawn step fails — the VM and its helpers keep running as systemd user services with no state file to reference. They become invisible to `epi list` and cannot be cleaned up via `epi rm`.

The `unit_id` (and therefore the slice name) is already generated before any processes spawn (`vm_launch.ml:394`), but it is only persisted inside the runtime object after full success.

## Goals / Non-Goals

**Goals:**
- Ensure every spawned systemd process group is always discoverable and cleanable via `epi rm`
- Minimize the window between "resources exist" and "state tracks them"
- Keep the change minimal — no new lifecycle state machines or phase enums

**Non-Goals:**
- Automatic cleanup of orphaned instances (user must run `epi rm`)
- Transactional rollback on partial launch failure (too complex, low value)
- Changing the `epi list` output format

## Decisions

### Decision: Write unit_id to state before spawning processes

After generating `unit_id` and before spawning passt, write a partial runtime to `state.json` containing just `unit_id` (and placeholder values for required fields). This makes the slice name reconstructable from state, so `epi rm` can stop it.

**Alternative considered — write a separate "phase" field:** Adds a new concept (`launching` / `provisioned`) that every consumer of state must handle. Increases complexity for all readers. Since the only thing we need is the `unit_id` to reconstruct the slice name, a partial runtime is simpler and backward-compatible.

**Alternative considered — write unit_id to a separate file:** Avoids touching `state.json` format, but adds a new file that every state reader must know about. The partial-runtime approach keeps everything in one file.

### Decision: Update runtime to full values after successful provision

After all processes are running and validated, overwrite the partial runtime with complete values (serial_socket, disk, ssh_port, ssh_key_path). This is the existing `set_provisioned` call, unchanged.

### Decision: Move state write into Vm_launch.provision

Currently `epi.ml` calls `Instance_store.set_provisioned` after `Vm_launch.provision` returns. The pre-spawn state write must happen inside `Vm_launch.provision` (specifically in `launch_detached`), since that's where `unit_id` is generated and processes are spawned. The post-spawn update stays in `epi.ml`.

Alternatively, `Vm_launch.provision` could return the `unit_id` early via a callback or two-phase return, but threading state writes into the caller adds complexity. Simpler for `launch_detached` to write the partial runtime itself.

### Decision: epi rm handles partial runtime gracefully

`epi rm` already reads runtime to get `unit_id`, constructs the slice name, and stops it. A partial runtime (unit_id present, other fields empty/placeholder) works with the existing cleanup code — `slice_name` only needs `instance_name` and `unit_id`. No changes needed to the rm path beyond ensuring it doesn't fail on empty `serial_socket` or `disk` values.

## Risks / Trade-offs

- **[Partial state visible to other commands]** → Between the pre-spawn write and the post-spawn update, `epi list` will show the instance and `instance_is_running` may return false (since the VM service hasn't started yet). This is acceptable — the instance *does* exist and showing it is correct. Commands that need the serial socket or SSH port will find empty/missing values and can report "not ready" or "not running".

- **[Crash between pre-spawn write and process start]** → State exists but no processes are running. `epi rm` will attempt to stop a non-existent slice (harmless no-op via systemctl) and then remove the state directory. Correct behavior.

- **[Double-write overhead]** → Two writes to `state.json` per launch instead of one. Negligible compared to nix eval and VM boot time.
