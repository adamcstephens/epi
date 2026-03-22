---
# epi-bqh5
title: Atomic descriptor cache writes via tempfile+rename
status: completed
type: task
priority: normal
created_at: 2026-03-22T23:23:57Z
updated_at: 2026-03-22T23:26:45Z
---

Replace fs::remove_file + fs::write with write-to-tempfile + fs::rename for atomic cache updates in src/target.rs
