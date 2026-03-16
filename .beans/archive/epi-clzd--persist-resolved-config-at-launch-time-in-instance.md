---
# epi-clzd
title: Persist resolved config at launch time in InstanceState
status: completed
type: task
priority: high
created_at: 2026-03-16T00:45:42Z
updated_at: 2026-03-16T00:45:42Z
parent: epi-u48p
---

In the launch command (lifecycle.rs), after config::resolve() produces final values, store cpus, memory_mib, disk_size, and port_specs into InstanceState before calling provision(). This is the write side — individual field issues handle the read side in start/rebuild.

Files: src/commands/lifecycle.rs (launch fn, ~line 44), src/instance_store.rs (InstanceState)

## Close Reason

Launch persists cpus, memory_mib, disk_size, port_specs into InstanceState. Verified in code at lifecycle.rs:39-45.
