## Why

genisoimage (from cdrkit) is unmaintained — its last release was in 2010. xorriso is actively maintained, widely available, and supports the same ISO 9660 generation features we need. Switching reduces reliance on abandoned software.

## What Changes

- Replace `genisoimage` invocation with `xorriso` in seed ISO generation
- Replace `cdrkit` dependency with `xorriso` in nix wrapper and dev shell
- Rename `EPI_GENISOIMAGE_BIN` env var to `EPI_XORRISO_BIN` — **BREAKING**
- Update mock genisoimage scripts in tests to mock xorriso instead
- Update error messages and hints to reference xorriso

## Capabilities

### New Capabilities

_(none)_

### Modified Capabilities

- `vm-user-provisioning`: ISO generation switches from genisoimage to xorriso; env var override changes name

## Impact

- `lib/vm_launch.ml`: seed ISO generation logic (command + env var + error types)
- `nix/wrapper.nix`, `flake.nix`: runtime and dev dependency swap (`cdrkit` → `xorriso`)
- `test/test_seed.ml`, `test/helpers/mock_runtime.ml`, `test/unit/test_provision_integration.ml`, `test/test_passt.ml`: mock scripts and assertions
- `openspec/specs/vm-user-provisioning/spec.md`: spec references genisoimage
