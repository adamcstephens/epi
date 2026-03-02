## Why

The flake currently exposes development and package outputs but no `nixosConfigurations` output, which makes it awkward to spin up a NixOS system configuration for manual validation. Adding a dedicated configuration now creates a stable target for end-to-end local testing before wider VM automation work.

## What Changes

- Add a `nixosConfigurations` output to `flake.nix` with at least one host configuration intended for manual testing.
- Wire the new configuration so developers can build and test it directly with standard Nix commands.
- Document the manual testing invocation and expected outcome in repository docs so the workflow is repeatable.

## Capabilities

### New Capabilities
- `nixos-manual-test-config`: Provide a flake-exposed NixOS configuration that can be built and manually exercised for local validation.

### Modified Capabilities
- None.

## Impact

- Affected code: `flake.nix` plus any new NixOS module/configuration files referenced by the flake output.
- Affected developer workflow: adds a concrete manual test target using `nix build`/`nixos-rebuild`-style flows.
- Affected docs: update developer documentation with manual testing steps.
