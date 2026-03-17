---
# epi-l5pe
title: RemoteCommand ends up in config
status: completed
type: task
priority: critical
created_at: 2026-03-18T02:08:47Z
updated_at: 2026-03-18T02:18:01Z
---

## Plan
- [x] Remove `project_dir` param from `generate_config` and `trust_host_key`
- [x] Remove `RemoteCommand`/`RequestTTY` from SSH config template
- [x] Pass `RemoteCommand`/`RequestTTY` as `-o` flags only in `cmd_ssh`
- [x] Update all callers to stop passing `project_dir` to SSH functions
- [x] Update tests
- [x] Lint + test

## Summary of Changes

Removed `RemoteCommand` and `RequestTTY force` from the persisted SSH config file. These directives are now passed as `-o` CLI flags only in `cmd_ssh`, so that `exec`, `cp`, `wait_for_ssh`, and other SSH-based operations use the config without interference.

Files changed:
- `src/ssh.rs`: Removed `project_dir` parameter from `generate_config` and `trust_host_key`
- `src/commands/access.rs`: `cmd_ssh` now reads `project_dir` from instance state and passes `RemoteCommand`/`RequestTTY` as `-o` flags
- `src/commands/lifecycle.rs`: Updated all callers
- `tests/e2e.rs`: Updated all callers
