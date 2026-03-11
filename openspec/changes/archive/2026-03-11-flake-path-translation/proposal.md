## Why

Users pass shorthand targets like `.#manual-test` which only works due to a flake alias. epi should translate these to their canonical form `.#nixosConfigurations.manual-test` and perform an eval check before resolving the full descriptor, giving a clear error if the attrpath doesn't exist.

## What Changes

- Translate user-provided target attrpaths to their canonical `nixosConfigurations` form before resolution
- Add a lightweight `nix eval` check against the translated attrpath to catch missing configs early with a user-friendly error

## Capabilities

### New Capabilities
- `flake-path-translation`: Translate shorthand flake targets to canonical nixosConfigurations attrpaths and validate they exist before full resolution

### Modified Capabilities

## Impact

- `lib/target.ml`: `resolve_descriptor` and related functions
- User-facing error messages when a target doesn't exist
