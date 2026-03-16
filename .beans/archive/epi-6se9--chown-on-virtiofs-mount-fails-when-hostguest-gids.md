---
# epi-6se9
title: chown on virtiofs mount fails when host/guest gids differ, aborting remaining mounts
status: completed
type: bug
priority: critical
created_at: 2026-03-16T00:45:42Z
updated_at: 2026-03-16T00:45:42Z
---

epi-init runs chown USERNAME: on each virtiofs mount after mounting. When host gid (100/users) differs from guest gid (999/adam), the chown fails. With errexit, this aborts the script before mounting subsequent filesystems. The chown is unnecessary — virtiofs preserves host ownership.

## Close Reason

Removed unnecessary chown from virtiofs mount loop in epi-init
