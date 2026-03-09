## 1. Core Implementation

- [x] 1.1 Add `exec_command` in `lib/epi.ml` that resolves the instance, validates SSH port availability, and `execvp`s into `ssh` with `-T` and the user-provided command
- [x] 1.2 Register `exec_command` in the command group in `lib/epi.ml`

## 2. Testing

- [x] 2.1 Add tests for `exec` subcommand help output and argument parsing
- [x] 2.2 Manual test: `dune exec --root . epi -- exec --help=plain` shows correct usage
