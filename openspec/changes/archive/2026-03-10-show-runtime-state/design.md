## Context

The `epi list` command currently outputs a two-column table (INSTANCE, TARGET). The `epi status` command shows `status: instance=<name> target=<target>` and optionally `SSH port: <port>`. Neither command shows whether the VM is actually running.

Runtime state is already persisted in `state.json` (the `runtime` field with `unit_id`, `ssh_port`, etc.), and `Instance_store.instance_is_running` already checks systemd unit liveness. The infrastructure exists — it just isn't surfaced in list/status output.

## Goals / Non-Goals

**Goals:**
- Show running/stopped status and SSH port in `epi list` output
- Show richer runtime details in `epi status` output
- Reuse existing `instance_is_running` and `find_runtime` functions

**Non-Goals:**
- JSON output format for list/status (future work)
- Resource usage (CPU, memory) display
- Filtering or sorting options for list

## Decisions

### List command adds STATUS and SSH columns

The list output becomes a four-column table: `INSTANCE  TARGET  STATUS  SSH`. For each instance, we call `Instance_store.find_runtime` and then `instance_is_running` to determine liveness. SSH port shows the port number or `-`.

**Alternative considered**: Only add a STATUS column without SSH. Rejected because the SSH port is the most actionable piece of runtime info — users need it to connect.

### Status command shows structured runtime fields

The status command output changes from the current ad-hoc format to a labeled field list:
```
Instance: dev-a
Target:   .#manual-test
Status:   running
SSH port: 54321
```

When stopped, runtime fields are omitted or show `-`.

**Alternative considered**: Keep the current `status: instance=... target=...` format and just append fields. Rejected because the current format is hard to parse visually and doesn't scale to more fields.

### Liveness check per instance in list

Each instance in `list` requires a systemd unit check (`systemctl --user is-active`). This is a subprocess per instance. For typical usage (1-5 instances), this is negligible. No batching or caching needed.

**Alternative considered**: Cache liveness in state.json. Rejected because stale cache is worse than a slightly slower list command, and the systemd check is fast.

## Risks / Trade-offs

- **[Performance with many instances]** → Each instance triggers a `systemctl` subprocess. Acceptable for expected usage (<10 instances). If needed later, could batch via `systemctl is-active unit1 unit2 ...`.
- **[Output format change]** → The list command's output format changes (new columns). Scripts parsing the old format will break. Mitigated by the fact that this is a dev tool with no stable output contract.
