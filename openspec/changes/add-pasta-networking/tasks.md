## 1. Pasta Binary Integration

- [x] 1.1 Add `EPI_PASTA_BIN` env var lookup in `vm_launch.ml`, defaulting to `pasta` on PATH, following the existing pattern of `EPI_CLOUD_HYPERVISOR_BIN`
- [x] 1.2 Add error handling for missing pasta binary with actionable message suggesting `EPI_PASTA_BIN` or installing the `passt` package

## 2. Network Argument Change

- [x] 2.1 Replace `--net tap=` with pasta-backed network argument in `vm_launch.ml` `launch_detached` function
- [x] 2.2 Verify cloud-hypervisor + pasta integration works by researching the correct `--net` flag format for pasta mode

## 3. Nix Packaging

- [x] 3.1 Add `passt` to devShell packages in `flake.nix`

## 4. Tests

- [x] 4.1 Update `test_epi.ml` assertions that check for `--net tap=` to match the new pasta-backed network argument
- [x] 4.2 Add test for `EPI_PASTA_BIN` env var override behavior
