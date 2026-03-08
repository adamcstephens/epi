## Why

The current `up`/`down` command names are vague and don't distinguish between creating a new VM instance and resuming an existing one. Users who have already created a VM and simply want to restart it have no way to do so without re-specifying `--target`, which is tedious and error-prone.

## What Changes

- **BREAKING** Rename `up` subcommand to `launch` — creates or starts an instance from a flake target (same behavior, new name)
- Add new `start` subcommand — starts an existing stopped instance by name, no `--target` required
- **BREAKING** Rename `down` subcommand to `stop` — stops a running instance (same behavior, new name)
- Update error messages and help text to reference new command names throughout

## Capabilities

### New Capabilities
- `vm-start-command`: A `start` subcommand that resumes an existing stopped instance without requiring `--target`, using the previously stored target from instance state.

### Modified Capabilities
- `dev-instance-cli`: The CLI surface changes — `up` becomes `launch`, `down` becomes `stop`, and `start` is added as a new lifecycle command. Error messages that reference `epi up` must be updated to `epi launch`.

## Impact

- `lib/epi.ml`: Rename `up_command`/`down_command` bindings, add `start_command`, update all `epi up`/`epi down` references in error messages and docstrings
- `openspec/specs/dev-instance-cli/spec.md`: Updated to reflect new command names and new `start` command
- Users with scripts or muscle memory using `epi up`/`epi down` will need to update
