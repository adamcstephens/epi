---
# epi-qfj0
title: tell user when project is detected/userd
status: completed
type: task
priority: high
created_at: 2026-03-16T00:45:43Z
updated_at: 2026-03-23T02:27:59Z
---

Print a message when a project config is detected and being used, so the user knows why behavior differs from global. Small UX feedback.

## Summary of Changes\n\nAdded `project_config: Option<PathBuf>` field to `config::Resolved` that is populated when a project config file is detected. The launch command in `main.rs` prints `using project config: <path>` via `ui::info()` when present.\n\nAlso moved `strip_home()` from `commands/info.rs` to `ui.rs` as a public shared utility.
