## Why

VMs launched by epi have no user accounts configured beyond NixOS defaults, so there's no way to log in as yourself. The serial console connects but you're stuck at a login prompt with no valid credentials. Users need to be able to log in to the VM with their host username to interact with the system after boot.

## What Changes

- Enable cloud-init in the NixOS VM configuration so user accounts can be provisioned at runtime without impure Nix evaluation
- At `epi up` time, generate a cloud-init NoCloud seed ISO containing `user-data` and `meta-data` with the host username and SSH public keys
- Attach the seed ISO as a second disk to cloud-hypervisor so cloud-init picks it up on first boot
- cloud-init creates the matching user with passwordless sudo, injects SSH keys, and configures auto-login on the serial console
- Enable SSH in the VM so the `epi ssh` command has a service to connect to

## Capabilities

### New Capabilities
- `vm-user-provisioning`: Generating a cloud-init NoCloud seed with the host username and SSH keys, attaching it to the VM, and having cloud-init create the matching user at runtime.

### Modified Capabilities
- `nixos-manual-test-config`: Enable cloud-init, SSH service, and networking in the manual-test NixOS module.

## Impact

- `nix/nixos/manual-test.nix` — Enable cloud-init, SSH service, and networking
- `lib/vm_launch.ml` — Generate cloud-init NoCloud seed ISO, attach as second disk to cloud-hypervisor
- `lib/epi.ml` — Potentially wire up the `ssh` stub to actually connect
- `flake.nix` — Add `cdrkit` (for `genisoimage`) to dev shell dependencies
