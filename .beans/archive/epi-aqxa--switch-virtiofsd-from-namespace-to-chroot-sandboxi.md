---
# epi-aqxa
title: Switch virtiofsd from namespace to chroot sandboxing
status: completed
type: bug
priority: critical
created_at: 2026-03-16T00:45:42Z
updated_at: 2026-03-16T00:45:42Z
---

virtiofsd namespace sandboxing causes permission issues. Switch to --sandbox chroot and drop uid/gid mapping flags (--uid-map, --gid-map, --translate-uid, --translate-gid).

## Close Reason

Fixed: switched to --sandbox none (chroot requires root, incompatible with --user systemd) and removed uid/gid mapping flags
