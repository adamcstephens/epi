## Context

Currently `resolve_descriptor` in `lib/target.ml` passes the user's target string directly to `nix eval --json <target>.config.epi`. Shorthand targets like `.#manual-test` only work because of flake aliases. The canonical form is `.#nixosConfigurations.manual-test`, and epi should translate to this form itself.

When a target doesn't exist, `nix eval` produces a verbose, hard-to-parse error. A quick eval check before full resolution would let epi surface a clear message.

## Goals / Non-Goals

**Goals:**
- Translate `<flake-ref>#<name>` to `<flake-ref>#nixosConfigurations.<name>` before resolution
- Run a lightweight eval check on the translated attrpath and produce a user-friendly error if it doesn't exist

**Non-Goals:**
- Supporting non-nixosConfigurations attrpaths (e.g. `packages`, `devShells`)
- Removing the flake alias — it can stay, epi just won't rely on it

## Decisions

**Always prefix with `nixosConfigurations`**: The config name portion of the target gets prefixed unconditionally. If the user already passes a full path like `.#nixosConfigurations.foo`, we don't double-prefix — detect and skip. This keeps the logic simple and predictable.

**Eval check via `nix eval <attrpath> --apply 'x: true'`**: This evaluates the attrpath just enough to confirm it exists without evaluating the full config. If it fails, epi reports a clear error like `target '.#nixosConfigurations.foo' not found in flake` with the nix stderr for context.

## Risks / Trade-offs

- [Extra nix eval call] → Adds a small latency cost on every launch. Acceptable since launches already do full nix eval.
- [Double-prefix if user passes full path] → Mitigated by checking if config name already starts with `nixosConfigurations.`.
