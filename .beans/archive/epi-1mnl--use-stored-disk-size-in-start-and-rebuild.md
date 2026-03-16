---
# epi-1mnl
title: Use stored disk_size in start and rebuild
status: completed
type: bug
priority: normal
created_at: 2026-03-16T00:45:42Z
updated_at: 2026-03-16T00:45:42Z
parent: epi-u48p
---

start and rebuild hardcode disk_size to 40G (lines 202, 346) instead of reading from the InstanceState disk_size field that's already persisted at launch.

Files: src/commands/lifecycle.rs (lines 202, 346), src/instance_store.rs (InstanceState.disk_size)

## Close Reason

Start/rebuild read state.disk_size with fallback to 40G (lifecycle.rs:206, 353). Launch persists resolved.disk_size (lifecycle.rs:41).
