---
# epi-36s4
title: Split main.rs command handlers into discrete modules
status: completed
type: task
priority: low
created_at: 2026-03-16T00:45:44Z
updated_at: 2026-03-16T00:45:44Z
---

main.rs is 825 lines with ~18 cmd_* handler functions all in one file. Split into a commands/ module grouped by relatedness: commands/lifecycle.rs (launch, start, stop, rm, rebuild), commands/access.rs (ssh, exec, cp, console), commands/info.rs (list, status, logs, ssh_config). main.rs stays as just fn main() + fn run() dispatch.

## Close Reason

Split main.rs into commands/ module: lifecycle.rs, access.rs, info.rs, init.rs
