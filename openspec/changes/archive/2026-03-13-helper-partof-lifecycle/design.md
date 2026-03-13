## Context

Helper processes (passt, virtiofsd) are cleaned up via `ExecStopPost` commands on the VM service that run `systemctl --user stop <helper>`. This causes a deadlock during slice stop: the `ExecStopPost` command blocks waiting on a helper that's already being torn down by the slice. The current workaround (`--no-block` + `-` prefix) is fragile.

systemd's `PartOf=` directive is designed exactly for this: "when unit X stops, stop me too." Setting `PartOf=<vm>.service` on each helper means systemd handles the propagation natively, avoiding the deadlock entirely.

## Goals / Non-Goals

**Goals:**
- Eliminate the deadlock on slice stop
- Use native systemd dependency directives instead of manual systemctl commands

**Non-Goals:**
- Cleaning up the empty slice after VM crash (accepted as a future cleanup item)
- Changing how `stop_instance` works (it still stops the slice)

## Decisions

### Use `PartOf=` on helper units instead of `ExecStopPost` on VM unit

`PartOf=<vm>.service` on each helper tells systemd to propagate stop from the VM to helpers. This works for both slice-initiated stops (no deadlock since systemd manages ordering) and VM-initiated exits (crash, guest shutdown).

Alternative: Keep `ExecStopPost` with `--no-block`. Rejected because it's a workaround for a problem that `PartOf=` solves natively.

### Pass VM unit name to `run_helper` for `PartOf=` property

`run_helper` needs to know the VM unit name to set `PartOf=`. Adding an optional `vm_unit` parameter keeps the function general while allowing callers to opt in.

Alternative: Always require the VM unit name. Rejected because `run_helper` is a general utility.

### Remove `helper_units` parameter from `service_properties`

With `PartOf=` on helpers and `After=` already on the VM service, `service_properties` no longer needs to know about helper units for ExecStopPost. The `After=` ordering still needs to be set on the VM service, so helper unit names are still passed for that.

## Risks / Trade-offs

- [Risk] Empty slice lingers after VM crash → Accepted; cleaned up on next `epi stop`/`epi rm`/`epi launch` for the instance
