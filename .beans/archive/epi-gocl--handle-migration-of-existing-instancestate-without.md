---
# epi-gocl
title: Handle migration of existing InstanceState without new fields
status: completed
type: task
priority: normal
created_at: 2026-03-16T00:45:42Z
updated_at: 2026-03-16T00:45:42Z
parent: epi-u48p
---

Existing instances won't have cpus, memory_mib, or port_specs in their state.json. Add serde defaults so deserialization doesn't break, and fall back to target descriptor defaults for pre-migration instances.

Files: src/instance_store.rs (InstanceState struct)

## Close Reason

cpus/memory_mib are now required u32 with serde(default) functions returning 1 and 1024. Old state files deserialize cleanly. Test: deserialize_missing_new_vm_param_fields.
