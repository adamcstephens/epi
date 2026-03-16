---
# epi-o47h
title: 'Refactor InstanceState creation: remove set_launching, rename save_target to init_state'
status: completed
type: task
priority: normal
created_at: 2026-03-16T00:45:42Z
updated_at: 2026-03-16T00:45:42Z
parent: epi-u48p
---

Replace set_launching() with direct InstanceState struct construction at call sites. The function hides simple struct init behind too many parameters (clippy too_many_arguments). Also rename save_target() to init_state() to better reflect its purpose. This simplifies the API and removes the need for the #[allow(clippy::too_many_arguments)] suppress.

## Close Reason

Removed set_launching and save_target. Callers now construct InstanceState directly and call save_state. Mount canonicalization extracted to canonicalize_mounts helper. Commit xvmksvls (a3d3de71).
