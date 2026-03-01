## 1. Command surface and parsing

- [x] 1.1 Define top-level commands: `up`, `rebuild`, `down`, `status`, `ssh`, `logs`, and `list`.
- [x] 1.2 Implement parsing for optional positional instance names with fallback to `default` where specified.
- [x] 1.3 Implement `--target <flake#config>` parsing and validation for `up`.
- [x] 1.4 Add help text and usage examples documenting instance-vs-target semantics.

## 2. Instance metadata contract

- [x] 2.1 Define and implement persistent mapping from instance name to target string.
- [x] 2.2 Ensure lifecycle commands resolve by instance name and load stored target where needed.
- [x] 2.3 Implement missing-instance and missing-default error paths with actionable guidance.

## 3. Command behavior scaffolding

- [x] 3.1 Implement `list` output showing instance names and associated targets.
- [x] 3.2 Add command stubs for `up`, `rebuild`, `down`, `status`, `ssh`, and `logs` that exercise resolved inputs.
- [x] 3.3 Ensure non-zero exits for invalid target syntax and unknown instances.

## 4. Validation and tests

- [x] 4.1 Add CLI tests covering explicit and implicit `default` instance selection.
- [x] 4.2 Add tests for invalid `--target` forms and expected error messages.
- [x] 4.3 Add tests for `list` output in empty and multi-instance states.
- [x] 4.4 Run `openspec validate initial-cli-layout --strict` and fix any artifact issues.
