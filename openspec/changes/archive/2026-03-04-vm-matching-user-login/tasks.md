## 1. NixOS Module: cloud-init and Services

- [x] 1.1 Enable `services.cloud-init` in the manual-test NixOS module (`nix/nixos/manual-test.nix`)
- [x] 1.2 Enable `services.openssh` with password authentication disabled
- [x] 1.3 Add `virtio_net` to `boot.initrd.availableKernelModules` for network device support
- [x] 1.4 Configure DHCP networking on the virtio-net interface

## 2. OCaml: Generate cloud-init NoCloud Seed ISO

- [x] 2.1 Add a function to read SSH public keys from `~/.ssh/*.pub`, logging a warning if none are found
- [x] 2.2 Add a function to generate `user-data` YAML with the host `$USER`, `wheel` group, passwordless sudo, and SSH keys
- [x] 2.3 Add a function to generate `meta-data` YAML with instance name as `instance-id` and `local-hostname`
- [x] 2.4 Add a function to invoke `genisoimage` to create a `cidata`-labeled ISO from `user-data` and `meta-data`, written to `<runtime-dir>/<instance>.cidata.iso`
- [x] 2.5 Check for `genisoimage` on `$PATH` before attempting ISO creation; fail with a clear error if missing

## 3. OCaml: Attach Seed ISO and Network to cloud-hypervisor

- [x] 3.1 Add the seed ISO as an additional `--disk path=<iso>,readonly=on` argument in `launch_detached`
- [x] 3.2 Add `--net tap=` argument to attach a virtio-net device

## 4. Nix: Dev Shell Dependencies

- [x] 4.1 Add `cdrkit` to the dev shell in `flake.nix` so `genisoimage` is available

## 5. Tests

- [x] 5.1 Add test that seed ISO generation creates valid `user-data` and `meta-data` files with correct content
- [x] 5.2 Add test that SSH keys are read from `~/.ssh/*.pub` and included in `user-data`
- [x] 5.3 Add test that missing SSH keys produce a warning but don't fail provisioning
- [x] 5.4 Add test that missing `genisoimage` produces a clear error
- [x] 5.5 Add test that the seed ISO is passed as an additional `--disk` argument to cloud-hypervisor
