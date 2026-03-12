## 1. Pre-spawn state write

- [x] 1.1 Add `Instance_store.set_launching` that writes target + partial runtime (unit_id only, empty strings for serial_socket/disk/ssh_key_path, None for ssh_port) to state.json
- [x] 1.2 Call `set_launching` inside `Vm_launch.launch_detached` after unit_id generation (line ~394) and before passt spawn, passing instance_name, target, and unit_id

## 2. Failure cleanup

- [x] 2.1 In `epi.ml` `provision_and_report`, on provision error: stop the slice (best-effort via unit_id if available) and remove state if the instance didn't exist before launch; clear runtime if it did
- [x] 2.2 Thread `unit_id` back through provision errors so the caller can reconstruct the slice name for cleanup (add unit_id field to relevant error variants, or return it alongside the error)

## 3. Tests

- [x] 3.1 Unit test: `set_launching` writes state.json with target and partial runtime containing unit_id
- [x] 3.2 Unit test: `set_provisioned` over a partial runtime produces complete state.json
- [x] 3.3 Integration test: provision failure after pre-spawn write cleans up state (fresh instance case)
- [x] 3.4 Integration test: interrupted launch leaves state discoverable by `list` and cleanable by `rm`
