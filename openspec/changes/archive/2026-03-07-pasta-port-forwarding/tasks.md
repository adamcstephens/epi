## 1. Port Allocation

- [x] 1.1 Add `alloc_free_port()` function in `vm_launch.ml` that binds a TCP socket to `127.0.0.1:0`, reads the assigned port, and closes the socket
- [x] 1.2 Pass `-T <port>:22` to the pasta invocation in `launch_detached`, using the allocated port

## 2. Runtime State

- [x] 2.1 Add `ssh_port : int option` field to the `runtime` record in `instance_store.ml`
- [x] 2.2 Update `write_runtime` to append `ssh_port` as a 7th TSV column (omit column if `None`)
- [x] 2.3 Update `read_runtime` to parse the optional 7th column as `ssh_port`; treat missing column as `None`
- [x] 2.4 Return `ssh_port` from `launch_detached` and store it via `Instance_store.write_runtime`

## 3. CLI Output

- [x] 3.1 In `epi.ml`, after successful `up`, print the forwarded SSH port (e.g., `SSH port: 54321`)
- [x] 3.2 In any `status`/inspection output that shows runtime info, include the SSH port when present

## 4. Tests

- [x] 4.1 Add unit test for `alloc_free_port()` verifying it returns a port in the valid range
- [x] 4.2 Update `test_epi.ml` mock pasta to accept and ignore `-T` arguments
- [x] 4.3 Add test asserting pasta is invoked with `-T <port>:22`
- [x] 4.4 Add test asserting `epi up` output includes the SSH port
- [x] 4.5 Add test asserting runtime TSV round-trips `ssh_port` correctly
- [x] 4.6 Add test asserting a TSV row without `ssh_port` column loads with `ssh_port = None`
