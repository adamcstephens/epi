---
# epi-zzsm
title: Persist cpus and memory in InstanceState
status: completed
type: bug
priority: high
created_at: 2026-03-16T00:45:42Z
updated_at: 2026-03-16T00:45:42Z
parent: epi-u48p
---

start and rebuild pass cpus_override: None and memory_override: None to provision(), falling back to target descriptor defaults instead of using the values resolved at launch time.

Fix: add cpus and memory_mib to InstanceState, persist at launch, read back in start/rebuild.

Files: src/instance_store.rs (InstanceState), src/commands/lifecycle.rs (lines 204-205, 348-349), src/vm_launch.rs (ProvisionParams)

## Close Reason

cpus/memory_mib persisted at launch (lifecycle.rs:42-43), read back in start/rebuild (lifecycle.rs:213-214, 360-361). Roundtrip test at instance_store.rs:583.
