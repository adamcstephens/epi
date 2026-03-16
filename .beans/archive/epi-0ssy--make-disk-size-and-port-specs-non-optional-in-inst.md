---
# epi-0ssy
title: Make disk_size and port_specs non-optional in InstanceState
status: completed
type: task
priority: normal
created_at: 2026-03-16T00:45:42Z
updated_at: 2026-03-16T00:45:42Z
parent: epi-u48p
---

disk_size and port_specs are still Option in InstanceState, but like cpus/memory_mib they are always set at launch via resolve(). Make them required u32/Vec<String> with serde defaults for old state files, matching the pattern from epi-pob.1.

## Close Reason

Made disk_size and port_specs non-optional in InstanceState with serde defaults for backward compat
