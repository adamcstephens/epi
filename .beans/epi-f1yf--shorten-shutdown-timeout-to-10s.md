---
# epi-f1yf
title: shorten shutdown timeout to 10s
status: completed
type: task
priority: high
created_at: 2026-03-16T00:45:42Z
updated_at: 2026-03-23T01:01:48Z
---

Likely a single constant change. Quick win.

## Summary of Changes\n\nReduced the shutdown script timeout from 15s to 10s in `generate_shutdown_script()` in `src/cloud_hypervisor.rs`. Updated doc comment and unit test to match.
