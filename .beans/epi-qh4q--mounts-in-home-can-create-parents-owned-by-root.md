---
# epi-qh4q
title: mounts in home can create parents owned by root
status: todo
type: bug
priority: normal
created_at: 2026-03-16T00:45:42Z
updated_at: 2026-03-22T23:31:32Z
---

When mounting paths under ~, intermediate directories may be created owned by root instead of the user. Needs careful investigation of the mount/mkdir flow.
