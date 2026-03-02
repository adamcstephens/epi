## Context

The `epi` CLI manages development VM instances using cloud-hypervisor. VMs run with detached serial console sockets. Currently, the `console` command exists as a placeholder but doesn't actually attach. The `up` command provisions VMs but has no immediate console attachment option.

## Goals / Non-Goals

**Goals:**
- Implement `epi console` as a native OCaml serial socket relay
- Add `--console` flag to `epi up` for immediate attachment after VM start
- Validate runtime state and serial socket availability before attach
- Handle both fresh provisioning and existing running instances

**Non-Goals:**
- Background console attachment (console is always foreground/interactive)
- Multiple simultaneous console sessions
- SSH-based console access

## Decisions

### Use in-process socket relay
**Decision:** Implement console attachment in OCaml by connecting to the Unix serial socket and relaying between stdin/stdout and the socket.
**Rationale:** Avoids external dependencies and works directly with cloud-hypervisor serial socket endpoints.
**Alternative considered:** External tooling for console attachment - rejected to keep behavior self-contained.

### Add attach retry for provisioning race
**Decision:** Retry serial socket connection for a short window when attach starts.
**Rationale:** `up --console` can race with socket readiness immediately after provisioning.
**Alternative considered:** Fail immediately on first connect error - rejected because it is flaky for startup attach.

### Up --console behavior
**Decision:** `up --console` provisions the VM, validates it started successfully, then attaches using the same native relay path as `console`.
**Rationale:** Users want to see the boot process immediately. The VM runs in background (detached), then we attach to it.
**Edge case handling:** If VM is already running, skip provisioning and attach directly to existing serial socket.

### Serial socket validation
**Decision:** Surface instance-specific errors for missing/unavailable serial endpoints.
**Rationale:** Provides clear guidance when runtime metadata exists but socket connectivity fails.

## Risks / Trade-offs

**[Risk]** Attach can race with socket startup during `up --console` → **Mitigation:** bounded connect retry before failing

**[Risk]** Long-running interactive relay can leave state stale if VM exits unexpectedly → **Mitigation:** keep existing runtime reconciliation and clear stale runtime on next command

**[Risk]** Terminal behavior differs from dedicated console tools → **Mitigation:** keep relay minimal and line-oriented; follow-up enhancements can add tty controls if needed

**[Trade-off]** Native relay simplicity vs advanced serial client features → **Accepted:** native relay is enough for attach workflows and removes dependency overhead

## Migration Plan

No migration needed - this is new functionality. Existing users can attach without installing extra console tools.

## Open Questions

None - implementation approach is clear.
