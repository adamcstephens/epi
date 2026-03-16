---
# epi-tjke
title: 'Multiple virtiofs mounts broken: only first mount passed to cloud-hypervisor'
status: completed
type: bug
priority: critical
created_at: 2026-03-16T00:45:42Z
updated_at: 2026-03-16T00:45:42Z
---

When multiple mounts are configured, build_args() emits a single --fs flag followed by all fs_args. Cloud-hypervisor only parses the first device spec, silently dropping the rest. Each fs device needs its own --fs flag.

## Close Reason

Not a bug: cloud-hypervisor uses single --fs with variadic args. E2E test confirms multi-mount works. Added multi-mount e2e coverage and unit tests.
