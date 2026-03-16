---
# epi-zjpu
title: state_dir and cache_dir return relative paths — canonicalize early
status: completed
type: bug
priority: normal
created_at: 2026-03-16T00:45:43Z
updated_at: 2026-03-16T00:45:43Z
---

Both instance_store::state_dir() and target::cache_dir() return EPI_STATE_DIR/EPI_CACHE_DIR env var values verbatim. When .envrc sets these to relative paths (.epi/state, .epi/cache), all downstream paths are relative. This creates inconsistency: Runtime fields (serial, disk, ssh_key) are absolute (re-canonicalized in vm_launch.rs), but computed paths (ssh_config, console_log, hook env state_dir, cache paths) are relative. Fix: canonicalize in state_dir()/cache_dir() themselves, handling the not-yet-exists case for cache_dir.

## Close Reason

Fixed by calling std::path::absolute in state_dir() and cache_dir()
