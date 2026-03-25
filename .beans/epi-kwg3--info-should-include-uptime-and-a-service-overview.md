---
# epi-kwg3
title: info should include uptime and a service overview
status: in-progress
type: task
priority: normal
created_at: 2026-03-18T02:43:49Z
updated_at: 2026-03-24T04:05:25Z
blocked_by:
    - epi-221o
---

Replace the current runtime section (file paths) with a live service tree and uptime. Ports and mounts already have their own sections.

## Design

Running:
```
runtime:                                           uptime 3d 14h
  epi-dev_6ee95003.slice
  ├─ epi-dev_6ee95003_vm.service
  ├─ epi-dev_6ee95003_passt.service
  ├─ epi-dev_6ee95003_virtiofsd0.service
  └─ epi-dev_6ee95003_virtiofsd1.service
```

Stopped:
```
runtime:   stopped
```

Also add `state:` row to the instance section showing the state directory path.

### Details
- Unit names use the raw instance name (not systemd-escaped). Use `systemd-escape --unescape` to convert back for display.
- Uptime from `ActiveEnterTimestamp` on the slice via `systemctl --user show`.
- List all units under the slice: vm, passt, and one virtiofsd per mount.
- Only show units that are active (query systemd).

## Tasks
- [ ] Add `unescape_unit_name` to process module
- [ ] Add state dir to instance section in info
- [ ] Replace runtime section with service tree + uptime
- [ ] Add unit tests for tree rendering and uptime formatting
- [ ] Changelog entry
