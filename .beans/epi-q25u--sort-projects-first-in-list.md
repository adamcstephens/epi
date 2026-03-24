---
# epi-q25u
title: sort projects first in list
status: completed
type: task
priority: normal
created_at: 2026-03-22T22:40:27Z
updated_at: 2026-03-24T03:24:54Z
---

Duplicate of epi-7gbp — both want project-scoped instances sorted before global ones in list output. Implement here, scrap the other.

## Summary of Changes

Sort project-scoped instances (those with a project_dir) before global ones in list output. Within each group, instances are sorted alphabetically by name.
