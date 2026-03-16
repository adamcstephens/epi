---
# epi-wkpw
title: Remove cpus_override/memory_override from ProvisionParams
status: completed
type: task
priority: low
created_at: 2026-03-16T00:45:43Z
updated_at: 2026-03-16T00:45:43Z
---

Once cpus and memory are always provided as concrete values (from resolved config at launch, or from stored state on start/rebuild), cpus_override and memory_override Options in ProvisionParams can be replaced with concrete u32 fields. This removes the fallback-to-descriptor-default logic in provision().

Files: src/vm_launch.rs (ProvisionParams lines 45-46, provision() lines 63-64)

## Close Reason

Closed
