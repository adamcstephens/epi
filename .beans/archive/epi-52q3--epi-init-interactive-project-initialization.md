---
# epi-52q3
title: 'epi init: interactive project initialization'
status: completed
type: feature
priority: normal
created_at: 2026-03-16T00:45:43Z
updated_at: 2026-03-16T00:45:43Z
---

Add an `epi init` command that initializes a new epi project with an interactive prompt.

**Default behavior (interactive):**
- Prompts for target (no default, must be provided)
- Prompts for default_name (default: project dir basename, accept with Enter)
- Prompts for cpus (default: 2, accept with Enter)
- Prompts for memory (default: 2048, accept with Enter)

**Flags:**
- `--no-confirm` / `-n`: Skip prompts, only populate default_name (from project dir basename). Target must still be provided as an argument or flag.

## Close Reason

Implemented epi init command with interactive and --no-confirm modes
