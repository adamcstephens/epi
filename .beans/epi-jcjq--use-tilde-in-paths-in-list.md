---
# epi-jcjq
title: use tilde in paths in list
status: completed
type: task
priority: high
created_at: 2026-03-22T22:40:56Z
updated_at: 2026-03-23T00:58:12Z
---

Small display tweak — replace home dir prefix with ~ in list output.

## Summary of Changes\n\nApplied `strip_home()` to the target column in `cmd_list()` and `cmd_info()`, so paths like `/home/user/.dotfiles#agents` now display as `~/.dotfiles#agents`. The `strip_home()` function already existed and was used for the PROJECT column — this extends it to TARGET as well. Added unit tests for `strip_home()`.
