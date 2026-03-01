## Why

The project currently has only template CLI scaffolding and no defined user-facing flow for creating and managing dev VMs from Nix flakes. A concrete command layout is needed now so implementation can proceed against stable UX and argument contracts.

## What Changes

- Define the initial top-level CLI command layout for instance lifecycle management: `up`, `rebuild`, `down`, `status`, `ssh`, `logs`, and `list`.
- Define instance identity as a first-class positional argument, with fallback to `default` when omitted.
- Define target identity as a required `--target <flake#config>` input for `up`, where the target follows standard `flake#config` syntax.
- Define multi-instance behavior and command disambiguation so instance selection and target selection are never conflated.
- Define baseline error handling semantics for missing default instances and invalid target format.

## Capabilities

### New Capabilities
- `dev-instance-cli`: CLI contract for creating and managing named dev VM instances from flake targets.

### Modified Capabilities
- None.

## Impact

- Affects CLI parsing and help text in `bin/` and `lib/`.
- Introduces persisted instance metadata requirements for mapping instance names to targets.
- Establishes the public command interface that follow-on runtime and VM lifecycle implementation will depend on.
