## Context

The current VM CLI requires users to stop an instance before removing it. Automation scripts need to call separate subcommands and handle failures when a VM remains running, which fragments control and produces noisy error handling.

## Goals / Non-Goals

**Goals:**
- Provide a single `vm rm` subcommand that either removes a stopped VM or forcefully kills a running one before removing it.
- Surface a clear `-f/--force` flag that terminates the VM when needed and documents the observable behavior.
- Keep existing VM lifecycle tooling compatible so automation can be updated without reworking the entire CLI.

**Non-Goals:**
- Adding support for bulk deletions, which will be handled separately.
- Introducing asynchronous background deletion flows; this command will remain synchronous.

## Decisions

- **Reuse existing VM lifecycle APIs:** Invoke the same termination and deletion routines as other CLI flows to avoid duplicating cleanup logic.
- **Force flag semantics:** When `-f/--force` is passed, attempt to stop the VM via the standard `terminate` path before issuing the delete call, treating any stop failure as fatal and surfacing an explanatory error.
- **Exit paths:** If the VM is already stopped, the command should delete it immediately without error. Without `--force`, running VMs should cause a refusal message instructing the operator to stop first.

## Risks / Trade-offs

- [Risk] Force-deleting a running VM may interrupt workloads unexpectedly. → Mitigation: Require explicit `-f/--force` and document the action prominently.
- [Risk] The command may be misused on critical infrastructure. → Mitigation: Encourage automation to inspect VM state before calling `vm rm` and include diagnostics in error messages.

## Migration Plan

1. Add the new subcommand and `--force` flag within the existing VM CLI module.
2. Update CLI docs and release notes to describe the command and safety considerations.
3. Notify automation owners so they can adjust workflows to use `vm rm` in place of separate stop/delete sequences.

## Open Questions

- None at this time.
