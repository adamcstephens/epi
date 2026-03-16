---
# epi-rbch
title: Add unit tests for three-way config merge through resolve()
status: completed
type: task
priority: low
created_at: 2026-03-16T00:45:44Z
updated_at: 2026-03-16T00:45:44Z
---

config::resolve() merges user config (EPI_CONFIG_FILE), project config (EPI_PROJECT_CONFIG_FILE), and CLI mounts, but no unit test exercises this full path. The existing resolve_cli_mounts_additive test manually reconstructs the merge logic instead of calling resolve(). Add unit tests that call resolve() with all three sources via env vars to verify mount union, dedup, and precedence.

## Close Reason

Added 9 unit tests exercising resolve() through env vars
