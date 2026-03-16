---
# epi-bm0c
title: launch ux updates
status: completed
type: task
priority: normal
created_at: 2026-03-16T00:45:43Z
updated_at: 2026-03-16T23:58:04Z
---

- [x] make first word consistently capitalized
- [x] Resolving -> Evaluating
- [x] Drop SSH port
- [x] Add indicator for other store paths, e.g. if kernel is already built list it as such
- [x] Leave time on completed lines
- [x] Use more granular time than whole minutes

## Summary of Changes

Updated launch UX in ui.rs and lifecycle.rs:
- Added elapsed time tracking (Instant) to Step and GroupStep, displayed on completion with sub-second granularity (e.g. 3.2s, 1m30.5s)
- Renamed Resolving -> Evaluating in resolve_with_ui
- Capitalized all status messages consistently
- Removed SSH port from ready messages
- Added all_artifacts() function to show cached store paths alongside build steps
- Added format_elapsed() with unit tests, all_artifacts() with unit tests
