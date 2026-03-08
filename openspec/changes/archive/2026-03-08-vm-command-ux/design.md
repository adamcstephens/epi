## Context

`epi` currently exposes `up` (create/launch from target) and `down` (stop). The `up` command requires `--target` on every invocation even for already-provisioned instances — there is no way to restart a stopped VM without re-specifying the flake target. The names `up`/`down` are informal and don't match the vocabulary users already have from tools like Docker and systemd.

## Goals / Non-Goals

**Goals:**
- Rename `up` → `launch` to make intent clear (provision + start from a target)
- Rename `down` → `stop` to match conventional vocabulary
- Add `start` command that resumes a stopped, already-provisioned instance using the stored target (no `--target` needed)
- Update all internal error messages and help text to reference the new names

**Non-Goals:**
- Backward-compatibility aliases for `up`/`down` — this is a breaking rename, not an additive change
- Changes to `launch` command behavior — only the name changes
- Changes to `stop` command behavior — only the name changes
- Any changes to instance state format or storage

## Decisions

### `start` reads target from instance store, not from CLI

**Decision**: `start` looks up the stored target in the instance store and relaunches the VM using it — no `--target` flag.

**Rationale**: The whole point of `start` is that the instance already exists. Requiring `--target` again would duplicate `launch`. Reusing the stored target (set during `launch`) is the correct source of truth.

**Alternative**: Accept an optional `--target` override on `start`. Rejected — adds complexity without clear benefit; if the target has changed, the user should use `launch`.

### No backward-compatibility aliases

**Decision**: Remove `up` and `down` entirely; do not keep them as hidden aliases.

**Rationale**: The codebase is small and all usages are internal. Keeping aliases would create confusion about which name is canonical. A clean break is simpler.

### `start` fails if instance does not exist

**Decision**: `start <instance>` exits non-zero if the named instance is not found in the instance store.

**Rationale**: `start` is for resuming existing instances. If the instance doesn't exist, the user needs `launch` — a clear error with guidance is the right behavior.

### `start` skips relaunch if already running

**Decision**: If the target instance is already running, `start` prints a notice and exits zero (same behavior as `launch` when already running).

**Rationale**: Idempotent behavior is preferable; running `start` on an already-running VM should not be an error.

## Risks / Trade-offs

- [Breaking change] Scripts or aliases using `epi up`/`epi down` will break → users must update; document in release notes
- [Behavior parity] `start` must replicate all of `launch`'s VM relaunch logic (stale PID cleanup, passt/virtiofsd cleanup) — risk of subtle divergence → reuse the same `Vm_launch.provision` path, just skip the `--target` argument requirement

## Migration Plan

1. Rename `up_command` → `launch_command` in `lib/epi.ml`, update registration key `"up"` → `"launch"`
2. Rename `down_command` → `stop_command`, update key `"down"` → `"stop"`
3. Implement `start_command`: look up instance in store, fail if missing, else run same provision/relaunch logic as `launch` using stored target
4. Update all `epi up`/`epi down` references in error messages, help text, and READMEs
5. No data migration needed — instance store format is unchanged
