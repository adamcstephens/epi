## 1. Two-pass config generation

- [x] 1.1 Write test for `generate_config` with `known_hosts: None` producing `StrictHostKeyChecking no` and `UserKnownHostsFile /dev/null`
- [x] 1.2 Write test for `generate_config` with `known_hosts: Some(path)` producing `StrictHostKeyChecking yes` and `UserKnownHostsFile <path>`
- [x] 1.3 Add `known_hosts` parameter to `generate_config` and implement the conditional logic
- [x] 1.4 Update all existing `generate_config` call sites to pass `None` (preserving current behavior)

## 2. Host key recording

- [x] 2.1 Write test for `record_host_key` that verifies it runs `ssh-keyscan` with the correct port and writes output to the known_hosts path
- [x] 2.2 Implement `ssh::record_host_key(port, known_hosts_path)` using `ssh-keyscan -p <port> 127.0.0.1`
- [x] 2.3 Write test that `record_host_key` returns `Ok(false)` on keyscan failure instead of erroring

## 3. Integrate into launch flow

- [x] 3.1 In `cmd_launch`, after `wait_for_ssh`, call `record_host_key` and if successful rewrite config with `known_hosts: Some(path)`
- [x] 3.2 In `cmd_start`, same pattern after `wait_for_ssh`
- [x] 3.3 In `cmd_rebuild`, same pattern after `wait_for_ssh`
- [x] 3.4 In the background thread (attach_console path of `cmd_launch`), same pattern

## 4. Verification

- [x] 4.1 Run `just format` and `just lint`
- [x] 4.2 Run `just test` to verify all unit tests pass
- [x] 4.3 Run `just test-e2e` to verify end-to-end tests pass
