## 1. Add NixOS Configuration Output

- [x] 1.1 Add a top-level `nixosConfigurations.manual-test` entry in `flake.nix` using `nixpkgs.lib.nixosSystem`.
- [x] 1.2 Create and wire a dedicated module/config file (for example `nix/nixos/manual-test.nix`) referenced by the `manual-test` host.
- [x] 1.3 Ensure existing `packages` and `devShells` outputs remain unchanged and still evaluate.

## 2. Manual Testing Workflow Documentation

- [x] 2.1 Add or update repository documentation with the canonical manual-test command for `nixosConfigurations.manual-test`.
- [x] 2.2 Document expected success criteria and basic failure triage guidance for the manual test flow.

## 3. Validation and Regression Checks

- [x] 3.1 Run `nix flake show` (or equivalent evaluation command) to verify `nixosConfigurations.manual-test` is exposed.
- [x] 3.2 Run the documented build command for `nixosConfigurations.manual-test.config.system.build.toplevel` and confirm successful evaluation/build.
- [x] 3.3 Run existing project checks relevant to flake evaluation to ensure no regressions were introduced.
