## Context

Cloud-hypervisor generates a random MAC address for the virtio-net device on every launch. When a VM is stopped and started, the persistent disk retains the guest OS's network configuration from the first boot, but the new random MAC causes DHCP/networking to fail inside the guest.

## Goals / Non-Goals

**Goals:**
- VM network interface has a stable MAC address across stop/start cycles
- SSH connectivity works after stop/start without guest-side changes

**Non-Goals:**
- Supporting multiple network interfaces per VM
- MAC address customization by the user

## Decisions

**Generate MAC from instance name using a hash**

Use `DefaultHasher` to hash the instance name and derive 5 bytes for the MAC. Set the first octet to `02` (locally administered, unicast). This gives a deterministic MAC per instance name with no additional state to manage.

Alternative considered: store the MAC in state.json. Rejected because it adds state management complexity for no benefit — the instance name is already a stable identifier.

**Pass MAC via `--net mac=` parameter**

Cloud-hypervisor's `--net` accepts a `mac=XX:XX:XX:XX:XX:XX` parameter. Add this to the existing net argument string in `build_args`.

## Risks / Trade-offs

- [Hash collision] Two instance names could produce the same MAC → Extremely unlikely with 40-bit space; acceptable for local-only VMs that don't share a network segment.
