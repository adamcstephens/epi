---
# epi-ks2u
title: Persist port_specs in InstanceState
status: completed
type: bug
priority: normal
created_at: 2026-03-16T00:45:42Z
updated_at: 2026-03-16T00:45:42Z
parent: epi-u48p
---

start and rebuild re-read only project config for ports via load_project(), ignoring user config and CLI port flags that were resolved at launch time. Port specs should be persisted in InstanceState at launch and read back on start/rebuild.

Files: src/commands/lifecycle.rs (lines 195-196, 206, 339-340, 350), src/instance_store.rs (InstanceState)

## Close Reason

port_specs persisted at launch (lifecycle.rs:44), read back in start/rebuild with fallback to project config (lifecycle.rs:201-205, 348-352). Roundtrip test at instance_store.rs:602.
