## 1. Foundation: Util module and dependency setup

- [x] 1.1 Add `yojson` to `dune-project` depends and `lib/dune` libraries
- [x] 1.2 Create `lib/util.ml` with `read_file`, `ensure_parent_dir`, `contains`, `parse_key_value_output` extracted from Target/Console/Process/Instance_store; change `read_file` to return `string option`
- [x] 1.3 Rename `Process.result` type to `Process.output`; update all callers across the codebase
- [x] 1.4 Verify build passes with `dune build --root .`

## 2. Target module: yojson and type enforcement

- [x] 2.1 Replace hand-rolled JSON parsing (`find_json_string`, `find_json_int`, `parse_json_string_array`, `configuredUsers` bracket scanning) with `Yojson.Basic.Util` in `descriptor_of_output`; remove dual key-value/JSON fallback — parse JSON only
- [x] 2.2 Rewrite `save_descriptor_cache` and `load_descriptor_cache` to use JSON via `Yojson.Basic.to_file`/`from_file`
- [x] 2.3 Enforce `Target.t` through internal APIs: `resolve_descriptor`, `resolve_descriptor_cached`, `validate_descriptor`, `cache_path` take `t` not `string`
- [x] 2.4 Flatten `validate_descriptor` using `let ( let* ) = Result.bind`
- [x] 2.5 Update callers in `Instance_store` and `Vm_launch` to use `Util.read_file` and `Util.parse_key_value_output` instead of `Target.*`
- [x] 2.6 Verify build passes and unit tests pass with `dune test --root .`

## 3. Process module: Result-based error handling

- [x] 3.1 Convert `Process.escape_unit_name` from `failwith` to `(string, string) result`; update callers in `Instance_store` and `Vm_launch`
- [x] 3.2 Remove duplicated `ensure_parent_dir` from `Process`; use `Util.ensure_parent_dir` instead
- [x] 3.3 Verify build passes

## 4. Vm_launch module: Result bind and pattern matching

- [x] 4.1 Convert `Vm_launch.generate_ssh_key` from `failwith` to `(string * string, provision_error) result`
- [x] 4.2 Replace `Option.is_some`/`Option.get` pattern with direct pattern matching for `non_dir_mount`
- [x] 4.3 Flatten `launch_detached` nested match chains using `let ( let* ) = Result.bind`
- [x] 4.4 Flatten `provision` nested match chain using `let*`
- [x] 4.5 Verify build passes and unit tests pass

## 5. Console module: deduplication and Result bind

- [x] 5.1 Remove duplicated `contains` from `Console`; use `Util.contains` instead
- [x] 5.2 Verify build passes

## 6. Epi module: extract duplicated logic

- [x] 6.1 Extract shared `provision_and_report` helper from duplicated branches in `launch_command` and `start_command`
- [x] 6.2 Verify build passes

## 7. Module interfaces

- [x] 7.1 Add `lib/target.mli` — expose `t` (abstract), `of_string`, `to_string`, `descriptor`, `resolution_error`, `cache_result`, `resolve_descriptor_cached`, `validate_descriptor`, `is_nix_store_path`, `descriptor_paths`, `default_cmdline`; hide JSON/parsing internals
- [x] 7.2 Add `lib/instance_store.mli` — expose `runtime`, `default_instance_name`, state CRUD functions, `vm_unit_name`, `slice_name`, `instance_is_running`, `find_running_owner_by_disk`; hide file I/O internals
- [x] 7.3 Add `lib/process.mli` — expose `output`, `run`, `env_with`, `escape_unit_name`, `generate_unit_id`, `unit_is_active`, `stop_unit`, `run_helper`, `run_service`, `systemctl_bin`, `ensure_parent_dir`; hide `setenv_args`
- [x] 7.4 Add `lib/console.mli` — expose `console_error`, `attach_console`, `pp_console_error`; hide `write_all`, `connect_serial_socket`, `contains`
- [x] 7.5 Add `lib/vm_launch.mli` — expose `provision_error`, `provision`, `pp_provision_error`; hide all internal helpers
- [x] 7.6 Verify build passes and all tests pass with `dune test --root .`

## 8. Final verification

- [x] 8.1 Run full test suite: `dune test --root .`
- [x] 8.2 Smoke test CLI: `dune exec --root . epi -- list`, `dune exec --root . epi -- launch --help=plain`
