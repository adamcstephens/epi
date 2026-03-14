## 1. Fix graceful shutdown

- [x] 1.1 Test: shutdown script shebang — unit test that `generate_shutdown_script` produces an absolute shebang (not `#!/usr/bin/env sh`)
- [x] 1.2 Add `sh_bin` parameter to `generate_shutdown_script`, use absolute path in shebang
- [x] 1.3 Resolve `sh` to absolute path in `launch_vm_inner` and pass to `generate_shutdown_script`
- [x] 1.4 Test: `shutdown-vmm` non-fatal — unit test that shutdown script contains `|| true` after `shutdown-vmm`
- [x] 1.5 Add `|| true` to `shutdown-vmm` line in `generate_shutdown_script`
- [x] 1.6 Test: `stop_instance` stops VM service before slice — unit or integration test verifying stop order
- [x] 1.7 Change `stop_instance` to stop VM service first, then slice

## 2. Console file capture via virtio-console

- [x] 2.1 Test: `build_args` emits `--console file=<path>` — unit test for new console_log field
- [x] 2.2 Add `console_log` field to `CloudHypervisorConfig`, change `--console off` to `--console file=<console_log>`
- [x] 2.3 Test: cmdline passes through to `build_args` — unit test that cmdline is forwarded unchanged
- [x] 2.4 Console ordering set in epi.nix cmdline default (`console=ttyS0 console=hvc0`)
- [x] 2.5 Pass `console_log` path to `CloudHypervisorConfig` in `launch_vm_inner`
- [x] 2.6 Add `virtio_console` to `boot.initrd.availableKernelModules` in `nix/nixos/epi.nix`

## 3. Remove in-process capture thread

- [x] 3.1 Remove `start_capture` function from `console.rs`
- [x] 3.2 Remove all `console::start_capture` call sites from `main.rs`
- [x] 3.3 Remove unused imports in `console.rs` (connect_socket if no longer needed by start_capture)

## 4. Update NixOS config

- [x] 4.1 Update `epi.nix` cmdline default to `console=ttyS0 console=hvc0` (hvc0 last = primary)

## 5. Validation

- [x] 5.1 Run `just test` — all unit tests pass
- [x] 5.2 Run `just test-e2e` — all 13 e2e tests pass
- [x] 5.3 Manual test: launch VM, stop, verify `console.log` is written by CH via virtio-console
- [x] 5.4 Manual test: `epi console` interactive attachment still works via serial socket
