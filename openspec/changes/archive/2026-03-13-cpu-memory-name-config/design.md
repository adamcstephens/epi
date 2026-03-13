## Context

The `epi` tool launches cloud-hypervisor VMs with CPU and memory values sourced from the nix target descriptor (`Descriptor.cpus` defaults to 1, `Descriptor.memory_mib` defaults to 1024). Changing these requires editing nix config and rebuilding. The instance name defaults to `"default"` via hardcoded strings in the CLI argument definitions.

The config system already supports three-tier precedence (CLI > project `.epi/config.toml` > user `~/.config/epi/config.toml`) for `target`, `mounts`, and `disk_size`. This change extends that pattern to CPU, memory, and default instance name.

## Goals / Non-Goals

**Goals:**
- Allow overriding CPU count and memory via `--cpus` and `--memory` CLI flags on `launch`
- Allow setting default CPU, memory, and instance name in config files
- Maintain existing precedence: CLI > project config > user config > descriptor default (for cpus/memory)
- For `default_name`: config > hardcoded `"default"`

**Non-Goals:**
- CPU topology (cores/threads/sockets) — just boot CPU count
- Memory units beyond MiB — keep it simple, match the descriptor's `memory_mib` unit
- Making `default_name` a CLI arg — it's a project/user preference, not a per-invocation choice
- Adding `--cpus`/`--memory` to `start` — start reuses the descriptor from the original launch

## Decisions

**Decision: CLI memory flag uses MiB to match descriptor**
The `--memory` flag accepts a plain integer in MiB, matching `Descriptor.memory_mib`. No suffix parsing (e.g., "2G") — keeps it simple and unambiguous. The config key is also `memory` in MiB.

*Alternative*: Accept human-friendly sizes like `"2G"`. Rejected — adds parsing complexity for a value users set once and rarely change. The descriptor already uses MiB.

**Decision: Config/CLI overrides apply after descriptor resolution**
CPU and memory from config/CLI override the descriptor values after nix eval. The `Resolved` struct carries `Option<u32>` for both — `None` means "use descriptor default". This avoids coupling config resolution to target resolution.

*Alternative*: Merge into the descriptor struct directly. Rejected — the descriptor represents the nix-side contract; overrides are a separate concern.

**Decision: `default_name` is config-only, not a CLI arg**
The default instance name is a project/user preference, not something that varies per invocation. If you want a specific name, you pass it as the positional arg. `default_name` just changes what "no name given" means.

**Decision: `default_name` applies to all commands that accept an optional instance name**
This includes `launch`, `start`, `stop`, `rebuild`, `ssh`, `exec`, `logs`, `status`, `rm`, `cp`. The resolution happens once in config, and the default is threaded through to clap's default value mechanism or applied at resolution time.

## Risks / Trade-offs

- [Descriptor defaults still apply when no override is set] → This is intentional — nix configs can set appropriate defaults per target, and CLI/config overrides are opt-in.
- [`default_name` mismatch between project members] → Project config (`.epi/config.toml`) is checked in, so teams share the same default. User config can override for personal preference.
