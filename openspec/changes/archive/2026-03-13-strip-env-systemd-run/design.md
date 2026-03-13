## Context

Both `run_helper` and `run_service` in `src/process.rs` iterate over `std::env::vars()` and pass every variable as `--setenv=K=V` to `systemd-run`. This was originally added to ensure processes could find binaries on PATH, but it forwards everything — shell config, credentials, editor settings, etc.

The spawned processes (cloud-hypervisor, passt, virtiofsd) are fully configured via CLI arguments and do not read any env vars for their operation. They are NixOS binaries with RPATH-linked dependencies, so they don't even need `PATH` or `LD_LIBRARY_PATH`.

## Goals / Non-Goals

**Goals:**
- Remove blanket env forwarding from `systemd-run` calls
- Transient units run with systemd's default minimal environment

**Non-Goals:**
- Adding a mechanism to selectively forward specific env vars (not needed today — no process requires it)
- Changing how `EPI_SYSTEMD_RUN_BIN` or `EPI_SYSTEMCTL_BIN` work (those are resolved in the CLI process, not forwarded to children)

## Decisions

**Remove env forwarding entirely rather than allowlisting specific vars.**

The three spawned binaries (cloud-hypervisor, passt, virtiofsd) are Nix-built with fully resolved paths. They don't need `PATH`, `HOME`, or any other env var — all configuration comes through CLI args. systemd's default environment (which includes `PATH` from the user's systemd session) is sufficient if any future binary does need it.

Alternative considered: forwarding only `PATH`. Rejected because Nix binaries don't need it and it would still leak information about the user's shell setup.

## Risks / Trade-offs

**Risk**: A future binary might need an env var from the user's session → Mitigation: Add targeted `--setenv` for that specific var when the need arises. This is a one-line change.
