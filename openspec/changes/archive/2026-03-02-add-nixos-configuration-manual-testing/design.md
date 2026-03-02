## Context

`flake.nix` currently defines `perSystem` outputs (`devShells` and `packages`) but does not expose a top-level `nixosConfigurations` attribute. This means developers cannot reference this repository directly as a NixOS system target for manual validation workflows. The change needs to add a minimal, buildable configuration and a clear way to exercise it locally without introducing broader deployment automation.

## Goals / Non-Goals

**Goals:**
- Add a `nixosConfigurations` output to `flake.nix` that evaluates on Linux and is intended for manual testing.
- Keep the configuration minimal and local-first, with explicit module wiring that is easy to inspect.
- Document a repeatable manual test command and expected success criteria.
- Avoid breaking existing flake outputs (`packages` and `devShells`).

**Non-Goals:**
- Full production host hardening or environment-specific profile management.
- Automatic VM lifecycle orchestration through `epi up` in this change.
- Managing secrets, remote deployment, or multi-host composition.

## Decisions

### 1. Add a top-level `flake.nix` `nixosConfigurations` output
Define a host entry such as `manual-test` under `flake.nix` using `nixpkgs.lib.nixosSystem`.

Rationale: this is the standard flake contract for NixOS systems and works with existing tooling.
Alternative considered: exposing only a custom package/module output. Rejected because it does not integrate directly with standard `nixosConfigurations` consumers.

### 2. Keep system configuration in a dedicated module file
Introduce a dedicated file (for example `nix/nixos/manual-test.nix`) and keep flake wiring thin.

Rationale: separates structure from wiring and keeps future host variants maintainable.
Alternative considered: inline module content in `flake.nix`. Rejected due to poor readability and harder extension.

### 3. Use explicit manual test command in docs
Document a deterministic command path (for example `nix build .#nixosConfigurations.manual-test.config.system.build.toplevel`) and expected result.

Rationale: allows local validation without requiring privileged switch/deploy commands.
Alternative considered: documenting only `nixos-rebuild`. Rejected because it can require root/system mutation and is less suitable as a baseline manual test.

### 4. Preserve existing outputs unchanged
Treat current `packages` and `devShells` behavior as compatibility constraints and avoid modifying their semantics.

Rationale: this change should add a manual-test capability, not alter existing development workflow.
Alternative considered: refactoring flake structure aggressively while adding `nixosConfigurations`. Rejected to minimize risk and review scope.

## Risks / Trade-offs

- [Configuration only evaluates for specific system architectures] -> Mitigation: explicitly set `system` for the manual-test host and validate with `nix flake show`/build command on supported architecture.
- [Manual-test host drifts from project runtime assumptions] -> Mitigation: keep host module minimal and focused on validating flake wiring, then evolve in follow-up changes as requirements solidify.
- [Documentation commands become stale] -> Mitigation: choose one canonical command tied to `nixosConfigurations.<name>` and include it in tests/checklist updates.
- [Adding top-level outputs can inadvertently break evaluation] -> Mitigation: keep dependencies explicit (`inputs.nixpkgs.lib`) and run local flake evaluation after edits.

## Migration Plan

1. Add a dedicated NixOS module/configuration file for manual testing.
2. Wire a `nixosConfigurations.manual-test` entry in `flake.nix` to that module.
3. Add or update documentation with a manual test command and expected output.
4. Validate flake evaluation and build path for the new host target.

Rollback strategy: remove the new `nixosConfigurations` wiring and module file, restoring the previous flake outputs-only behavior.

## Open Questions

- Should the manual-test configuration include cloud-hypervisor-specific defaults now, or remain a generic baseline NixOS system?
- Which repository document should own manual test instructions long-term (`README`, dedicated dev docs, or OpenSpec task notes)?
