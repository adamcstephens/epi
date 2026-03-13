## Why

After stopping and starting a VM, SSH connections fail because cloud-hypervisor generates a random MAC address on every launch. The guest OS retains its network configuration (DHCP lease, interface state) from the first boot on the persistent disk, but the new MAC causes the guest's networking to break on subsequent boots.

## What Changes

- Generate a deterministic MAC address from the instance name so it remains stable across stop/start cycles
- Pass the MAC to cloud-hypervisor via the `--net mac=` parameter
- Add an e2e test that validates SSH connectivity survives a stop/start cycle

## Capabilities

### New Capabilities

- `stable-vm-mac`: Deterministic MAC address generation for VM network interfaces, ensuring stable networking across instance restarts

### Modified Capabilities

## Impact

- `src/cloud_hypervisor.rs`: `build_args` gains a `mac` parameter added to the `--net` argument
- `src/vm_launch.rs`: Generates a stable MAC from the instance name and passes it through
- `tests/e2e.rs`: New e2e test for stop/start SSH connectivity
