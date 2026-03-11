## 1. Target Translation

- [x] 1.1 Add `canonicalize_target` function in `lib/target.ml` that translates `<flake-ref>#<name>` to `<flake-ref>#nixosConfigurations.<name>`, skipping if already prefixed
- [x] 1.2 Call `canonicalize_target` in `resolve_descriptor` before the `nix eval` call

## 2. Eval Check

- [x] 2.1 Add `check_target_exists` function that runs `nix eval <attrpath> --apply 'x: true'` and returns a user-friendly error on failure
- [x] 2.2 Call `check_target_exists` in `resolve_descriptor` after canonicalization but before full eval

## 3. Tests

- [x] 3.1 Unit tests for `canonicalize_target` (shorthand, already-canonical, edge cases)
- [x] 3.2 Integration test for eval check error path using mock resolver
