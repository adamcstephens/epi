---
# epi-arzx
title: Make Resolved and InstanceState VM params non-optional
status: completed
type: task
priority: high
created_at: 2026-03-16T00:45:42Z
updated_at: 2026-03-16T00:45:42Z
parent: epi-u48p
---

Push resolution of VM defaults upstream so Resolved has cpus: u32, memory: u32, disk_size: String, ports: Vec<String> (no Options). InstanceState mirrors with cpus: u32, memory_mib: u32, disk_size: String, port_specs: Vec<String> using serde defaults for old state files. This ensures required values are always present and trusted after resolution.

## Close Reason

Resolved.cpus and .memory are now u32 with defaults (1, 1024). Removed cpus/memory_mib from Descriptor and nix module. ProvisionParams uses cpus/memory_mib directly instead of _override Option.
