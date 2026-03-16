---
# epi-azk6
title: add upgrade capability
status: todo
type: task
created_at: 2026-03-16T03:19:57Z
updated_at: 2026-03-16T03:19:57Z
---

can compute kernel, initrd, and toplevel. then orchestrate a `boot` application of the toplevel, stop the instance, and swap the kernel/initrd. would need to update state and gcroots. don't need to store toplevel still, it's copied into the instance
