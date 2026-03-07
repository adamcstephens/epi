## 1. Split vm_launch.ml — extract console.ml

- [x] 1.1 Create `lib/console.ml` with `write_all`, `connect_serial_socket`, `attach_console`, `console_error` type, and `pp_console_error`
- [x] 1.2 Add `console` library to `lib/dune`
- [x] 1.3 Update `lib/epi.ml` to reference `Console` module instead of `Vm_launch` for console functions and error types
- [x] 1.4 Remove console code from `vm_launch.ml`
- [x] 1.5 Build clean, tests pass

## 2. Split vm_launch.ml — expand target.ml

- [x] 2.1 Move `descriptor` type, `default_cmdline`, and parsing helpers (`parse_key_value_output`, `find_json_string`, `find_json_int`, `descriptor_of_output`) into `target.ml`
- [x] 2.2 Move target resolution and artifact helpers into `target.ml`: `resolve_descriptor`, `split_target`, `store_root_of_path`, `ensure_store_realized`, `build_target_artifact_if_missing`, `is_nix_store_path`, `descriptor_paths`, `all_paths_share_parent`, `validate_descriptor_coherence`, `validate_descriptor`
- [x] 2.3 Move shared utilities (`contains`, `lowercase`, `read_file_if_exists`) into `target.ml`
- [x] 2.4 Update `lib/dune` — `target` library is now a dependency of `vm_launch`
- [x] 2.5 Update all call sites in `vm_launch.ml` and `epi.ml` to use `Target.` prefix
- [x] 2.6 Remove moved code from `vm_launch.ml`
- [x] 2.7 Build clean, tests pass

## 3. Descriptor cache — core implementation

- [x] 3.1 Add `cache_dir ()` to `target.ml` returning `~/.local/state/epi/targets/`
- [x] 3.2 Add `cache_path target` to `target.ml`: `Digest.string target |> Digest.to_hex` → path in `cache_dir`
- [x] 3.3 Add `save_descriptor_cache target descriptor` to `target.ml`: write key-value file (kernel, disk, initrd, cmdline, cpus, memory_mib) to `cache_path target`
- [x] 3.4 Add `load_descriptor_cache target` to `target.ml`: read and parse cache file if it exists, return `descriptor option`
- [x] 3.5 Add `descriptor_paths_exist descriptor` to `target.ml`: check all artifact paths in descriptor exist on disk
- [x] 3.6 Add `resolve_descriptor_cached ~rebuild target` to `target.ml`: delete cache if `rebuild=true`, return cached descriptor if valid (file exists + paths exist), else call `resolve_descriptor`, cache result, return it
- [x] 3.7 Update `provision` in `vm_launch.ml` to call `Target.resolve_descriptor_cached` instead of `Target.resolve_descriptor`

## 4. --rebuild CLI flag

- [x] 4.1 Add `--rebuild` flag to `epi up` subcommand in `epi.ml`
- [x] 4.2 Thread `rebuild` bool through `provision ~rebuild ~instance_name ~target`
- [x] 4.3 Pass `~rebuild` to `Target.resolve_descriptor_cached`

## 5. Tests

- [x] 5.1 Add test: cache is written after successful provision (check cache file exists after up)
- [x] 5.2 Add test: second `epi up` on same target uses cache (mock resolver not called second time)
- [x] 5.3 Add test: cache with missing path triggers re-eval (delete a path, verify resolver called again)
- [x] 5.4 Add test: `--rebuild` busts cache and re-evals unconditionally
- [x] 5.5 Verify all existing tests still pass
