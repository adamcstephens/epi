---
# epi-nj9l
title: 'Investigate disk build performance: ext4 vs btrfs'
status: completed
type: task
priority: low
created_at: 2026-03-16T00:45:43Z
updated_at: 2026-03-16T00:45:43Z
---

Benchmark how long it takes to build the manual-test disk image. Compare ext4 (current) vs btrfs filesystem in repart config. Goal: determine if btrfs builds faster.

## Close Reason

Benchmarked: no meaningful build speed difference, btrfs images 2.4x larger. Not worth switching.
