---
# epi-5c21
title: add memory ballooning
status: completed
type: task
priority: high
created_at: 2026-03-17T13:18:53Z
updated_at: 2026-03-17T23:00:54Z
---

## Plan
- [x] Add `virtio_balloon` to guest kernel modules in `nix/nixos/epi.nix`
- [x] Add `--balloon size=0,deflate_on_oom=on,free_page_reporting=on` to `build_args()` in `src/cloud_hypervisor.rs`
- [x] Add test for balloon args
- [x] Lint and test

## Decisions
- Always enabled, balloon size=0 at launch (zero cost when not used)
- No resize CLI command — just enable the device
- No persistence — balloon resets to 0 on every launch
- `deflate_on_oom=on` for safety, `free_page_reporting=on` for host reclaim

## Summary of Changes

Enabled virtio memory balloon device on all cloud-hypervisor VMs. Added `--balloon size=0,deflate_on_oom=on,free_page_reporting=on` to launch args and `virtio_balloon` to guest kernel modules. Balloon starts at size=0 (no memory reclaimed) — zero cost when not actively used. `deflate_on_oom` ensures guest safety, `free_page_reporting` enables passive host memory reclaim.
