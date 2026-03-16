---
# epi-l780
title: Rename --no-wait to --no-provision
status: completed
type: bug
priority: high
created_at: 2026-03-16T00:45:42Z
updated_at: 2026-03-16T00:45:42Z
---

Rename --no-wait to --no-provision since it skips SSH wait + host key trust + hooks (i.e. provisioning), not just waiting. Also rename EPI_NO_WAIT env var to EPI_NO_PROVISION.

## Close Reason

Renamed --no-wait to --no-provision with updated specs and help text
