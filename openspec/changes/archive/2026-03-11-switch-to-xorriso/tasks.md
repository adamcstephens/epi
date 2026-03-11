## 1. Core Implementation

- [x] 1.1 In `lib/vm_launch.ml`: rename `Genisoimage_missing` → `Xorriso_missing`, rename `genisoimage_bin` → `xorriso_bin`, change env var from `EPI_GENISOIMAGE_BIN` to `EPI_XORRISO_BIN`
- [x] 1.2 In `lib/vm_launch.ml`: update `generate_seed_iso` to invoke `xorriso -as mkisofs` instead of `genisoimage` (same flags: `-output`, `-volid epidata`, `-joliet`, `-rock`)
- [x] 1.3 Update error messages to reference `xorriso` instead of `genisoimage`/`cdrkit`

## 2. Nix Dependencies

- [x] 2.1 In `nix/wrapper.nix`: replace `cdrkit` with `xorriso` in PATH
- [x] 2.2 In `flake.nix`: replace `cdrkit` with `xorriso` in devShells packages

## 3. Tests

- [x] 3.1 Update `test/helpers/mock_runtime.ml`: rename mock script and env var to `EPI_XORRISO_BIN`
- [x] 3.2 Update `test/test_seed.ml`: adjust assertions for xorriso error messages
- [x] 3.3 Update `test/unit/test_provision_integration.ml`: rename mock script and env var
- [x] 3.4 Update `test/test_passt.ml`: rename mock script and env var
- [x] 3.5 Run `dune test` and verify all tests pass

## 4. Specs

- [x] 4.1 Update `openspec/specs/vm-user-provisioning/spec.md` to reference xorriso instead of genisoimage
