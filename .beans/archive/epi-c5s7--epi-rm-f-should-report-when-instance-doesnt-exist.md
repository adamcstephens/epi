---
# epi-c5s7
title: epi rm -f should report when instance doesn't exist
status: completed
type: bug
priority: low
created_at: 2026-03-16T00:45:44Z
updated_at: 2026-03-16T00:45:44Z
---

When running 'epi rm -f <name>' for a non-existent instance, the command succeeds silently (green). It should report that no instance was found.

## Close Reason

Fixed: rm now checks instance existence before proceeding. With -f, prints info message; without -f, returns error.
