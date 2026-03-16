---
# epi-k1hn
title: add EPI_PROJECT_DIR to hook env
status: completed
type: task
priority: normal
created_at: 2026-03-16T00:45:43Z
updated_at: 2026-03-16T05:49:35Z
---

## Tasks

- [x] Add `project_dir: Option<String>` to `HookEnv` struct
- [x] Add `EPI_PROJECT_DIR` to env vars in `execute()`
- [x] Pass `project_dir` at all 3 construction sites in lifecycle.rs
- [x] Update test constructions in hooks.rs and e2e.rs
- [x] Tests pass


## Summary of Changes

Added `project_dir: Option<String>` to `HookEnv` and conditionally set `EPI_PROJECT_DIR` env var in hook execution. All 3 lifecycle call sites (launch, stop, rebuild) now pass project_dir through. Added unit tests for both Some and None cases.
