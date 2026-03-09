## 1. Seed ISO: add epi-mounts file

- [x] 1.1 In `vm_launch.ml` `generate_seed_iso`, write an `epi-mounts` file to the staging directory (one path per line) when `mount_paths` is non-empty
- [x] 1.2 Remove mount-related `write_files` and `runcmd` blocks from `generate_user_data`

## 2. Host state: persist mount paths

- [x] 2.1 Add `save_mounts` and `load_mounts` to `instance_store.ml` (write/read `mounts` file, one path per line)
- [x] 2.2 In `vm_launch.ml` `launch_detached`, call `Instance_store.save_mounts` after virtiofsd starts successfully
- [x] 2.3 In `epi.ml` `start` command, read saved mount paths via `Instance_store.load_mounts` and pass them to `Vm_launch.provision` instead of `[]`

## 3. NixOS guest: systemd generator

- [x] 3.1 Write a bash generator script in `nix/nixos/epi.nix` that: finds `/dev/disk/by-label/cidata`, mounts it read-only to a tmpdir, reads `epi-mounts`, emits one `.mount` unit per path (with `ExecStartPre=mkdir -p`), then unmounts
- [x] 3.2 Register the generator via `systemd.generators` in the NixOS module

## 4. Verification

- [x] 4.1 `dune build` passes
- [x] 4.2 Launch a VM with `--mount`, stop it, `epi start` it, verify mounts present on second boot
