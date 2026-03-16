---
# epi-px01
title: project_dir includes .epi/ subdirectory instead of project root
status: completed
type: bug
priority: normal
created_at: 2026-03-16T00:45:43Z
updated_at: 2026-03-16T00:45:43Z
---

config::project_dir() uses path.parent() on .epi/config.toml which gives .epi/, not the project root. Should use the base directory (second tuple element from project_config_path()) or go up two levels.

## Close Reason

Fixed project_dir() to use base from project_config_path() instead of path.parent()
