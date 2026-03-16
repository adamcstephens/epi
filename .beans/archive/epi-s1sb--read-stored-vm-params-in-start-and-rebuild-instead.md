---
# epi-s1sb
title: Read stored VM params in start and rebuild instead of re-resolving
status: completed
type: task
priority: high
created_at: 2026-03-16T00:45:42Z
updated_at: 2026-03-16T00:45:42Z
parent: epi-u48p
---

start and rebuild should read cpus, memory_mib, disk_size, and port_specs from the stored InstanceState instead of hardcoding defaults or partially re-resolving config. Pass concrete values to provision().

Files: src/commands/lifecycle.rs (start ~line 194, rebuild ~line 338)

## Close Reason

Start and rebuild read cpus, memory_mib, disk_size, port_specs from stored InstanceState. Fallbacks for old instances via serde defaults and or_else chains. Verified at lifecycle.rs:201-215 and 348-362.
