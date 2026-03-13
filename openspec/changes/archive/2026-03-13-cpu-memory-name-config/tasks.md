## 1. Config: add cpus, memory, default_name fields

- [x] 1.1 Add unit tests for parsing cpus, memory, default_name from config TOML
- [x] 1.2 Add unit tests for merge_configs with new fields (project overrides user, fallback behavior)
- [x] 1.3 Add `cpus: Option<u32>`, `memory: Option<u32>`, `default_name: Option<String>` to `Config` struct
- [x] 1.4 Add `cpus: Option<u32>`, `memory: Option<u32>`, `default_name: String` to `Resolved` struct
- [x] 1.5 Update `merge_configs` to merge new fields with project-over-user precedence
- [x] 1.6 Update `resolve()` signature to accept `cli_cpus: Option<u32>`, `cli_memory: Option<u32>` and apply CLI > config precedence
- [x] 1.7 Resolve `default_name` in `resolve()`: config value or `"default"` fallback

## 2. CLI: add --cpus and --memory flags to launch

- [x] 2.1 Add `--cpus` and `--memory` clap args to the `launch` command
- [x] 2.2 Pass CLI cpus/memory values through to `config::resolve()`
- [x] 2.3 Thread `Resolved.cpus` and `Resolved.memory` to VM launch, applying overrides to descriptor before cloud-hypervisor invocation

## 3. CLI: replace hardcoded "default" instance name with config default_name

- [x] 3.1 Add integration test: launch without instance name uses default_name from config
- [x] 3.2 Update all commands that accept optional instance name to use `Resolved.default_name` instead of hardcoded `"default"`

## 4. Verification

- [x] 4.1 Run `just test` to verify unit and integration tests pass
- [x] 4.2 Run `just format` to ensure code formatting
- [x] 4.3 Manual test: `just run launch` with `--cpus` and `--memory` flags
- [x] 4.4 Run `just test-e2e` for end-to-end verification
