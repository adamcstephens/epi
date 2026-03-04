## 1. Instance Store

- [x] 1.1 Add `passt_pid : int option` field to `Instance_store.runtime` type
- [x] 1.2 Update `runtime_of_fields` to parse a 6th tab-separated field as `passt_pid`, defaulting to `None` for 5-field rows
- [x] 1.3 Update `save` to write `passt_pid` as a 6th field (empty string when `None`)

## 2. VM Launch

- [x] 2.1 Return `passt_pid = Some _pasta_proc.pid` in the `Ok runtime` result from `launch_detached`

## 3. Pasta Cleanup

- [x] 3.1 Add a `kill_if_alive` helper in `epi.ml` (and `instance_store.ml`) that sends SIGTERM to a pid, ignoring `ESRCH`
- [x] 3.2 In `terminate_instance_runtime`, send SIGTERM to `passt_pid` (best-effort, after killing hypervisor)
- [x] 3.3 In `reconcile_runtime`, send SIGTERM to `passt_pid` before clearing stale runtime entries
- [x] 3.4 In the `up` stale-relaunch path, kill `passt_pid` from the stale runtime before calling `clear_runtime`

## 4. Tests

- [x] 4.1 Update `with_mock_runtime` to track that the mock pasta process is started and that its pid appears in instance state after `epi up`
- [x] 4.2 Add test: after `epi down`, the passt process is no longer alive (wired up `down` to call `terminate_instance_runtime`)
- [x] 4.3 Add test: on `epi up` over a stale instance, the old passt process is terminated before the new one starts
