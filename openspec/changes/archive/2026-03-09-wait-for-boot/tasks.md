## 1. Runtime state: make ssh_key_path non-optional

- [x] 1.1 Change `ssh_key_path` from `string option` to `string` in `Instance_store.runtime` type (`instance_store.ml` and `instance_store.mli`)
- [x] 1.2 Update `save_runtime` to always write `ssh_key_path` (remove `match` on option)
- [x] 1.3 Update `load_runtime` to require `ssh_key_path` — return `None` if the field is missing (treats old runtimes as stale)
- [x] 1.4 Update all pattern matches on `runtime.ssh_key_path` across the codebase (ssh_command, exec_command in `epi.ml`)
- [x] 1.5 Update tests that construct `runtime` values with `ssh_key_path = None` or `Some`

## 2. Make SSH key generation unconditional

- [x] 2.1 Remove `~generate_ssh_key` parameter from `launch_detached` and `provision` in `vm_launch.ml`
- [x] 2.2 Always call `generate_ssh_key` in `launch_detached` — remove the conditional branch
- [x] 2.3 Update `vm_launch.mli` to remove `generate_ssh_key` from `provision` signature
- [x] 2.4 Remove `--generate-ssh-key` flag from `launch_command` in `epi.ml`
- [x] 2.5 Update `start_command` to always generate a key (currently passes `~generate_ssh_key:false`)
- [x] 2.6 Update `provision_and_report` to remove `~generate_ssh_key` parameter
- [x] 2.7 Update tests referencing `--generate-ssh-key` flag or `~generate_ssh_key` parameter

## 3. Add wait_for_ssh function

- [x] 3.1 Add `Ssh_wait_timeout` variant to `provision_error` in `vm_launch.ml`
- [x] 3.2 Add `pp_provision_error` case for `Ssh_wait_timeout`
- [x] 3.3 Implement `wait_for_ssh ~ssh_port ~ssh_key_path ~timeout_seconds` in `vm_launch.ml` — loop running `ssh -o ConnectTimeout=5 ... true` every 2 seconds until success or timeout
- [x] 3.4 Expose `wait_for_ssh` in `vm_launch.mli`

## 4. Add --no-wait and --wait-timeout CLI flags

- [x] 4.1 Add `--no-wait` flag to `launch_command` in `epi.ml`
- [x] 4.2 Add `--wait-timeout` named option (int) to `launch_command` in `epi.ml`
- [x] 4.3 Add `--no-wait` flag to `start_command` in `epi.ml`
- [x] 4.4 Add `--wait-timeout` named option (int) to `start_command` in `epi.ml`
- [x] 4.5 Add timeout resolution logic: `--wait-timeout` flag > `EPI_WAIT_TIMEOUT_SECONDS` env var > default 120

## 5. Integrate wait into provisioning flow

- [x] 5.1 Update `provision_and_report` to accept `~no_wait` and `~wait_timeout` parameters
- [x] 5.2 After successful `Vm_launch.provision`, call `Vm_launch.wait_for_ssh` unless `no_wait` is true
- [x] 5.3 Print progress message before wait: `"vm: waiting for SSH (timeout %ds)..."`
- [x] 5.4 Print `"vm: SSH ready"` on successful wait
- [x] 5.5 Pass `~no_wait` and `~wait_timeout` from both `launch_command` and `start_command`

## 6. Manual testing

- [x] 6.1 Verify `epi launch --target '.#manual-test' test1` waits for SSH and succeeds
- [x] 6.2 Verify `epi exec test1 -- echo hello` works immediately after launch completes
- [x] 6.3 Verify `epi launch --target '.#manual-test' --no-wait test2` returns before SSH is ready
- [x] 6.4 Verify `epi ssh test1` connects using the generated key
- [x] 6.5 Clean up test instances
