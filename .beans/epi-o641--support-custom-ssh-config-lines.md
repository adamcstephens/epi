---
# epi-o641
title: support custom SSH config lines
status: completed
type: feature
priority: normal
created_at: 2026-04-04T06:12:23Z
updated_at: 2026-04-04T13:28:04Z
---

Allow users to specify extra SSH config lines (ssh_extra_config) in user/project config that get appended to the generated SSH config. This enables LocalForward for socket forwarding, ForwardAgent, and any other SSH option without code changes.

## Tasks
- [x] Add `ssh_extra_config` field to `Config` struct
- [x] Add `ssh_extra_config` field to `Resolved` struct
- [x] Add `ssh_extra_config` field to `InstanceState` struct (persisted)
- [x] Merge `ssh_extra_config` across user/project configs (union, deduped)
- [x] Update `generate_config()` to accept and append extra lines
- [x] Update `trust_host_key()` to pass through extra config
- [x] Update all call sites in lifecycle.rs and e2e tests
- [x] Add unit tests for config parsing, merging, and SSH generation
- [x] Lints pass
- [x] Tests pass
- [x] E2E tests pass
- [x] Committed

## Summary of Changes
Added `ssh_extra_config` option to user/project config that appends arbitrary SSH config lines to the generated per-instance SSH config. Lines are merged (union, deduped) across user and project configs, persisted in instance state, and applied on both initial config generation and after host key trust.
