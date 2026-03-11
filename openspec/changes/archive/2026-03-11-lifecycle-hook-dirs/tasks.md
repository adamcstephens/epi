## 1. Hook discovery module

- [x] 1.1 Create `lib/hooks.ml` with function to discover executable files from a single hook directory (lexically sorted, executable only, warn on non-executable)
- [x] 1.2 Add instance subdirectory discovery — collect `<instance>/*` after top-level files
- [x] 1.3 Add multi-layer discovery — combine user-level and project-level directories in order
- [x] 1.4 Write unit tests for discovery: no dirs, empty dirs, mixed executable/non-executable, instance filtering, layer ordering

## 2. Host hook execution

- [x] 2.1 Add hook execution function that runs scripts sequentially with environment variables (`EPI_INSTANCE`, `EPI_SSH_PORT`, `EPI_SSH_KEY`, `EPI_SSH_USER`, `EPI_STATE_DIR`), failing on non-zero exit
- [x] 2.2 Integrate `post-launch` hooks into `epi launch` after SSH wait (skip when `--no-wait`)
- [x] 2.3 Integrate `pre-stop` hooks into `epi stop` before systemd unit termination
- [x] 2.4 Write unit tests for execution: env vars set, failure stops chain, empty hook list is no-op

## 3. Guest hook embedding in seed ISO

- [x] 3.1 Collect guest hook scripts during provision using the same discovery module
- [x] 3.2 Write collected scripts into the seed ISO directory alongside `epi.json`
- [x] 3.3 Write unit tests for guest hook collection and ISO content generation

## 4. Guest hook execution in epi-init

- [x] 4.1 Update `nix/nixos/epi.nix` epi-init service to detect and execute hook scripts from seed ISO as provisioned user via `su -`
- [x] 4.2 Add first-boot guard so guest hooks only run on initial provision (not reboots)
- [x] 4.3 Ensure hook failures are logged but do not block boot (exit 0 regardless)

## 5. Integration testing

- [ ] 5.1 Add CLI integration test: launch with post-launch hook, verify hook ran (check side effect)
- [x] 5.2 Add CLI integration test: stop with pre-stop hook, verify hook ran
- [x] 5.3 Run full test suite (`dune test`) and verify no regressions
- [ ] 5.4 Manual test: launch VM with guest-init hook, verify script executed as user inside VM
