## Code style
- Follow ocaml-conventions skill
- Avoid abstractions
- Avoid wrapping single expressions in standalone functions
- Prefer explicit namespace references

## Dependencies
- OCaml deps are in `_build` — read code from there, not via ocamlfind or the web
- Never pull OCaml deps from nixpkgs, only use dune pkg

## Testing
- Use red/green TDD
- Quick tests: `dune test` (runs unit + CLI integration concurrently)
- Unit only: `dune exec test/unit/test_unit.exe`
- CLI only: `dune exec test/test_epi.exe -- _build/default/bin/epi.exe --quick-tests`
- Individual groups: `... -- test <group>` (unit: `test epi_json`, `test cache`, `test provision`; CLI: `test launch`, `test seed`)
- List groups: `... -- list`
- E2E (requires real VM): `dune exec test/e2e/test_e2e.exe -- -e`
- When possible, manually test: e.g. `dune exec epi -- list`
- Use `--help=plain` for CLI help (without `=plain`, pager hangs non-interactively)

## Testing against a real VM
- Launch: `dune exec epi -- launch <NAME> --target '.#manual-test'`
- Exec: `dune exec epi -- exec <NAME> -- ls /`
- Remove: `dune exec epi -- rm -f <NAME>`
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
