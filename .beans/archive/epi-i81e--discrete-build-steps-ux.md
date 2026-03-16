---
# epi-i81e
title: discrete build steps ux
status: completed
type: task
priority: normal
created_at: 2026-03-16T00:45:43Z
updated_at: 2026-03-16T00:45:43Z
---

Refactor the opaque 'Provisioning' spinner into discrete, indented build steps with state transitions.

**Current behavior:** A single spinner covers all of nix eval + nix build + VM launch: 'Provisioning <name>' → '✓ Provisioned <name>'. No visibility into what's happening.

**Desired UX:**

```
◇ Preparing
  ⠋ Evaluating .#config
  ✓ Evaluated .#config
  ⠋ Building kernel /nix/store/...   (store path in grey)
  ✓ Built kernel /nix/store/...
  ⠋ Building initrd /nix/store/...
  ✓ Built initrd /nix/store/...
  ⠋ Building image /nix/store/...
  ✓ Built image /nix/store/...
✓ Prepared
```

Cache hit scenario:
```
◇ Preparing
  ◆ Cached .#config
✓ Prepared
```

**Implementation:**

1. **UI module (ui.rs):** Add Phase (parent with ◇/✓, no spinner) and SubStep (indented spinner, same mechanics as Step) alongside the existing Step.

2. **Split nix builds:** Instead of a single nix build for toplevel+image, build each artifact individually via its NixOS attribute (config.system.build.kernel, config.system.build.initialRamdisk, config.system.build.image), each with its own sub-step spinner. Order: kernel → initrd → image.

3. **Drive UI from cmd_launch:** Pull the nix resolution out of provision() so cmd_launch (and cmd_rebuild, cmd_start) can wrap each step with UI. resolve_descriptor_cached() already returns CacheResult::Cached vs CacheResult::Resolved — use this to show ◆ Cached vs ✓ Evaluated.

4. **Replace ensure_paths_exist:** Instead of checking all paths then doing one bulk build, check each path individually and build missing ones as separate sub-steps.

**Out of scope:** SSH wait and post-launch hooks UX (keep existing Step spinners).

## Close Reason

Implemented discrete build steps UX with Group/GroupStep UI, per-artifact nix builds, and cache-aware resolution display
