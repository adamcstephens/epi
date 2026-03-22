---
# epi-ft28
title: filter descriptor users to non-system users
status: completed
type: task
priority: high
created_at: 2026-03-19T18:17:50Z
updated_at: 2026-03-22T23:42:19Z
---

Add a filter to exclude system users (uid < 1000 or similar) from descriptor user list. Quick win, cleaner output.

## Summary of Changes\n\nFiltered `configuredUsers` in the NixOS module (`nix/nixos/epi.nix`) to only include users with `isNormalUser = true`, excluding system accounts like nixbld, nobody, sshd, messagebus, etc. Previously all 41 users from `config.users.users` were included.
