---
# epi-gxwy
title: Merge user and project mount configs instead of overriding
status: completed
type: feature
priority: normal
created_at: 2026-03-16T00:45:43Z
updated_at: 2026-03-16T00:45:43Z
---

Currently mounts use project-overrides-user semantics (project.mounts.or(user.mounts)), while ports use union merge. This is inconsistent and surprising — if a user has a user-level mount for dotfiles and a project-level mount for the project directory, both should apply. Change mounts to use union merge with dedup, matching port behavior. CLI --mount should add to the merged set for consistency, with a --no-default-mounts flag as an escape hatch to suppress config mounts entirely.

## Close Reason

Mounts now use union merge between user and project configs, matching port behavior. CLI --mount is additive.
