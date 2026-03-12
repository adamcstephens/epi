## Code style
- Follow ocaml-conventions skill
- Avoid abstractions
- Avoid wrapping single expressions in standalone functions
- Prefer explicit namespace references
- Prefer `result` or `option` over bare `unit` return types at module boundaries (`.mli` files)
- Never return `unit` from I/O functions that can fail
- Format code with `just format`

## Dependencies
- OCaml deps are in `_build` — read code from there, not via ocamlfind or the web
- Never pull OCaml deps from nixpkgs, only use dune pkg

## Testing
- Always execute red/green TDD
- Ensure you run e2e tests at least once before finalizing
- Quick tests: `just test` (runs unit + CLI integration concurrently)
- Unit only: `just test-unit`
- CLI only: `just test-cli`
- Individual groups: `... -- test <group>` (unit: `test epi_json`, `test cache`, `test provision`; CLI: `test launch`, `test seed`)
- List groups: `... -- list`
- E2E (requires real VM): `just test-e2e`
- E2E individual groups: `just test-e2e e2e-setup`. You *must* test e2e-setup first in order to force a rebuild before testing other e2e groups.
- When possible, manually test: e.g. `just run list`
- Use `--help=plain` for CLI help (without `=plain`, pager hangs non-interactively)

## Testing against a real VM
- Launch: `just run launch <NAME> --target '.#manual-test'`
- Exec: `just run exec <NAME> -- ls /`
- Remove: `just run rm -f <NAME>`
- SSH keys are auto-generated during provisioning
- Rebuild only when changing nix config, to save time

## Nix
- Quote targets to avoid shell prompting: `'.#manual-test'` not `.#manual-test`

## Instance state
- Stored in `.epi/state/` (relative to project root), NOT `~/.local/state/epi/`
- Set via `EPI_STATE_DIR` env var

## Git worktrees
- Created at `.worktrees/<name>/`
- Must create from HEAD if .jj directory exists
- Must create a branch on initialization
- Always pass `--root .` to dune commands (build, exec, test, pkg lock)
  - Without it, dune finds the outermost `dune-workspace` and fails
- Build, explore, and run commands in the worktree directory — never the parent
- Search/read files using the worktree path
