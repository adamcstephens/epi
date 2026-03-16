---
# epi-4yt3
title: Shell tab completion for subcommands, flags, and instance names
status: completed
type: feature
priority: high
created_at: 2026-03-16T00:45:42Z
updated_at: 2026-03-16T00:45:42Z
---

Add tab completion support for fish, bash, and zsh. Use clap_complete with CompleteEnv for dynamic runtime completions (including instance names) and a completions subcommand for static script generation. Install completions via nix packaging.

## Close Reason

Implemented shell tab completion for fish/bash/zsh using clap_complete with CompleteEnv for dynamic runtime completions and a completions subcommand for static script generation. Nix wrapper installs completion scripts automatically.
