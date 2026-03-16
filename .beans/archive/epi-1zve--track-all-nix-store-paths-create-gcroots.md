---
# epi-1zve
title: track all nix store paths, create gcroots
status: completed
type: task
priority: normal
created_at: 2026-03-16T00:45:43Z
updated_at: 2026-03-16T00:45:43Z
---

When nix-collect-garbage runs, all store paths epi depends on can be swept away. A stopped instance becomes unlaunchable — kernel, initrd, and backing disk image are gone. Hook scripts referenced by store path also vanish.

Solution: create GC roots for critical runtime paths at provision time.

Location: .epi/state/<instance>/gcroots/ with symlinks for:
- kernel
- disk (base image — critical since qcow2 overlay references it)
- initrd
- each hook script (post-launch, pre-stop, guest-init)

Registration: nix-store --add-root (works unprivileged, any user can call it)

Lifecycle:
- Create: at provision time, after descriptor resolution succeeds
- Remove: implicit — when 'rm' deletes the instance state dir, nix notices dead symlinks on next GC

Scope: only root paths directly referenced at launch time. The full toplevel/system closure is not rooted — it can be rebuilt from the target if needed. The cost of keeping two copies of the full system outweighs the low probability of needing a rebuild.

State: store the full resolved descriptor in state.json. This makes instances self-contained — gcroots can be reconstructed from state alone without re-resolving the nix target.

Flow: single pass — resolve descriptor, store in state, create all gcroots from it. No separate bookkeeping step. The descriptor is the single source for what gets rooted.

## Close Reason

Implemented gcroots creation at provision time with descriptor stored in state.json
