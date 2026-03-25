---
# epi-xgrl
title: fix render_list tests failing in nix build sandbox
status: completed
type: bug
priority: normal
created_at: 2026-03-26T02:52:59Z
updated_at: 2026-03-26T02:53:37Z
---

render_list uses ContentArrangement::Dynamic which depends on terminal width detection. In nix build sandbox there's no TTY, so table renders empty and tests fail.

## Summary of Changes\n\nRemoved `ContentArrangement::Dynamic` from `render_list()` in `src/commands/info.rs`. This arrangement mode depends on terminal width detection via `is_terminal()`, which returns false in the nix build sandbox, causing the table to render empty. The default arrangement (`Disabled`) uses natural column widths and works in both TTY and non-TTY environments.
