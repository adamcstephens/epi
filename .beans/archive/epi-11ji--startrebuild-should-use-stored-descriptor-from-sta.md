---
# epi-11ji
title: start/rebuild should use stored descriptor from state
status: completed
type: task
priority: low
created_at: 2026-03-16T00:45:43Z
updated_at: 2026-03-16T00:45:43Z
---

After epi-ikf, the resolved descriptor is stored in state.json. cmd_start and cmd_rebuild still call prepare_and_provision which re-resolves the descriptor from nix. They should use the stored descriptor when available, falling back to resolution only when missing (old state) or when --rebuild forces re-evaluation. This avoids unnecessary nix eval calls and ensures the instance uses the same descriptor it was originally provisioned with.

## Close Reason

cmd_start uses stored descriptor from state.json, skipping nix eval
