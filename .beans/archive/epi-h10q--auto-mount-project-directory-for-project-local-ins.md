---
# epi-h10q
title: Auto-mount project directory for project-local instances
status: completed
type: feature
priority: high
created_at: 2026-03-16T00:45:42Z
updated_at: 2026-03-16T00:45:42Z
---

When launching an instance from a project directory (where .epi/config.toml exists), automatically mount the project directory into the guest. This removes the need to explicitly set mounts = ["."] in config.toml for the common case. Can be disabled with --no-project-mount CLI flag or project_mount = false in config.

## Close Reason

Implemented auto-mount of project directory in config::resolve()
