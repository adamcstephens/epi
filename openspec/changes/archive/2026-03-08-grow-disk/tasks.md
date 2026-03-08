## 1. NixOS Guest Configuration

- [x] 1.1 Add `boot.growPartition = true` to `nix/nixos/epi.nix`
- [x] 1.2 Add `fileSystems."/".autoResize = true` to `nix/nixos/epi.nix`
- [x] 1.3 Verify `nix build .#nixosConfigurations.manual-test.config.system.build.toplevel` succeeds

## 2. qemu-img Resize in OCaml

- [x] 2.1 Add `Vm_disk_resize_failed` error variant to `vm_launch.ml`
- [x] 2.2 Add `find_qemu_img` helper to locate `qemu-img` via `EPI_QEMU_IMG_BIN` or PATH (same pattern as `virtiofsd`/`pasta`)
- [x] 2.3 Add `resize_disk` function that calls `qemu-img resize <path> <size>` and returns `Vm_disk_resize_failed` on non-zero exit
- [x] 2.4 Call `resize_disk` in `ensure_writable_disk` after the copy, only for newly created overlays
- [x] 2.5 Add `resize_disk_format_error` arm in `format_launch_error`

## 3. CLI --disk-size Flag

- [x] 3.1 Add `disk_size` field (string option) to the `up` subcommand argument record in `epi.ml`
- [x] 3.2 Wire `--disk-size` Cmdliner argument with default `"40G"`
- [x] 3.3 Pass `disk_size` through to `Vm_launch.launch`
- [x] 3.4 Thread `disk_size` into `ensure_writable_disk` / `resize_disk`

## 4. Tests

- [x] 4.1 Add unit test: `resize_disk` returns error when `qemu-img` binary is absent
- [x] 4.2 Add unit test: `ensure_writable_disk` skips resize when overlay already exists
- [x] 4.3 Run full test suite and confirm all tests pass

## 5. Manual Smoke Test

- [x] 5.1 Run `dune exec epi -- up --target '.#manual-test' --disk-size 5G` and confirm VM boots
- [x] 5.2 SSH into the VM and confirm `df -h /` shows ~5 GiB available
- [x] 5.3 Re-run `epi up` on the same instance and confirm no resize occurs
