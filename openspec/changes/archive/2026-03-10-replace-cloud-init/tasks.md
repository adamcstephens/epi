## 1. NixOS guest: add epi-init service

- [x] 1.1 Write epi-init bash script in epi.nix using `pkgs.writeShellApplication` — mounts epidata ISO, reads `epi.json` with `jq`, creates user, sets hostname, creates and starts virtiofs mount units
- [x] 1.2 Add `epi-init.service` systemd unit (Type=oneshot, RemainAfterExit=yes, After=local-fs.target, Before=multi-user.target sshd.service, WantedBy=multi-user.target)
- [x] 1.3 Remove `services.cloud-init.enable = true` from epi.nix
- [x] 1.4 Remove `epi-mounts-generator` and `systemd.generators.epi-mounts` from epi.nix
- [x] 1.5 Remove `networking.hostName = lib.mkForce ""` (epi-init sets hostname via hostnamectl)
- [x] 1.6 Add `jq` to guest packages for epi-init JSON parsing

## 2. Host-side: replace seed ISO with epidata JSON

- [x] 2.1 Replace `generate_user_data` and `generate_meta_data` in vm_launch.ml with a single `generate_epi_json` that produces `epi.json` using Yojson
- [x] 2.2 Update `generate_seed_iso` — write `epi.json` instead of `user-data`/`meta-data`/`epi-mounts`; change volume label from `cidata` to `epidata`; rename ISO file to `epidata.iso` and staging dir to `epidata`
- [x] 2.3 Update any references to `cidata.iso` in the codebase (cloud-hypervisor disk arg, state storage)

## 3. Tests

- [x] 3.1 Update test_seed.ml to verify `epi.json` format instead of cloud-config YAML
- [x] 3.2 Run e2e tests to verify VM boots, user is created, SSH works, and mounts function correctly
