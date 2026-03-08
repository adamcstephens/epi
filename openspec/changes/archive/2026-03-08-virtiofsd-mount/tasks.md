## 1. NixOS Guest Configuration

- [x] 1.1 Add `virtiofs` to `boot.initrd.availableKernelModules` in `nix/nixos/epi.nix`

## 2. virtiofsd Daemon Management

- [x] 2.1 Add virtiofsd binary lookup with `EPI_VIRTIOFSD_BIN` env var fallback (same pattern as passt) in `vm_launch.ml`
- [x] 2.2 Add `Virtiofsd_missing` and `Virtiofsd_failed` error variants to `provision_error`
- [x] 2.3 Implement virtiofsd launch: start detached process with vhost-user socket in instance dir, wait for socket readiness
- [x] 2.4 Add `virtiofsd_pid` field to `Instance_store.runtime` record and update persistence logic

## 3. Cloud-Hypervisor Integration

- [x] 3.1 Build `--fs` argument for cloud-hypervisor when mount is requested (tag=`hostfs`, socket path, etc.)
- [x] 3.2 Wire `--fs` arg into the `base_args` list in `launch_detached`

## 4. Cloud-Init Mount Configuration

- [x] 4.1 Extend `generate_user_data` to accept an optional mount path and emit `mounts:` directive with virtiofs type, mounting to the same absolute path as the host source directory (include `bootcmd` with `mkdir -p` to ensure the mount point exists)
- [x] 4.2 When `user_exists = false` and mount is requested, include `uid: <host_uid>` (from `Unix.getuid ()`) in the cloud-init user entry so virtiofs file ownership is correct

## 5. CLI Flag

- [x] 5.1 Add `--mount PATH` optional argument to the `up` command in `epi.ml`
- [x] 5.2 Thread mount path through `provision` and `launch_detached` function signatures

## 6. Instance Cleanup

- [x] 6.1 Update `epi down` to kill virtiofsd process using stored `virtiofsd_pid`

## 7. Testing

- [x] 7.1 Add virtiofsd to nix dev shell / flake dependencies
- [x] 7.2 Manual test: `epi up --target '.#manual-test' --mount` and verify the host directory is mounted at the same path inside the guest
