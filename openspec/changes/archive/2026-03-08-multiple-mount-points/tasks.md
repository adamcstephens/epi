## 1. Instance State

- [x] 1.1 Replace `virtiofsd_pid : int option` with `virtiofsd_pids : int list` in `Instance_store.runtime`
- [x] 1.2 Update serialisation to write `virtiofsd_pids=N,M,...` (omit field when empty)
- [x] 1.3 Update deserialisation to read `virtiofsd_pids` and add compat path for legacy `virtiofsd_pid=N`

## 2. CLI

- [x] 2.1 Change `--mount` from `Arg.named_opt` to `Arg.opt_all` so it can be repeated, producing `string list`
- [x] 2.2 Update all call sites that pass `mount_path` to pass `mount_paths`

## 3. VM Launch

- [x] 3.1 Update `generate_user_data` to accept `mount_paths : string list` and emit one systemd mount unit per path
- [x] 3.2 Update `generate_seed_iso` signature to pass `mount_paths`
- [x] 3.3 In `launch_detached`, loop over `mount_paths` to start one `virtiofsd` per path with socket `virtiofsd-<n>.sock` and tag `hostfs-<n>`
- [x] 3.4 Collect all virtiofsd PIDs into a list and pass to instance state as `virtiofsd_pids`
- [x] 3.5 Pass all `--fs tag=hostfs-<n>,socket=<sock>` arguments to cloud-hypervisor

## 4. Teardown

- [x] 4.1 Update `epi down` (and stale runtime cleanup in `epi up`) to iterate `virtiofsd_pids` and kill each process

## 5. Tests

- [x] 5.1 Add unit tests for `generate_user_data` with multiple mount paths
- [x] 5.2 Add unit tests for instance state round-trip with multiple PIDs and legacy compat read
