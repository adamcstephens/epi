- Follow ocaml-conventions skill
- Avoid abstractions
- Avoid singular functions with one or fewer lines.
- Explicit namespace references are preferred
- Use red/green TDD
- Run quick tests (`dune test`) during development — this runs both unit tests and CLI integration tests concurrently
- Run unit tests only: `dune exec test/unit/test_unit.exe`
- Run CLI integration tests only: `dune exec test/test_epi.exe -- _build/default/bin/epi.exe --quick-tests`
- Run individual test groups: unit tests with `dune exec test/unit/test_unit.exe -- test <group>` (e.g. `test epi_json`, `test cache`, `test provision`), CLI tests with `dune exec test/test_epi.exe -- _build/default/bin/epi.exe test <group>` (e.g. `test launch`, `test seed`)
- List available groups: `dune exec test/unit/test_unit.exe -- list` or `dune exec test/test_epi.exe -- _build/default/bin/epi.exe list`
- Run e2e tests (requires real VM): `dune exec test/e2e/test_e2e.exe -- -e`
- When possible, manually test by yourself, e.g. `dune exec epi -- list`
- When running commands that take a nix target, quote them to avoid prompting. e.g. `.#manual-test` -> `'.#manual-test'`
- ocaml dependencies are available in `_build`. Read code from there instead of using ocamlfind, reading outside the working directory or accessing the web.
- Never pull ocaml project deps from nixpkgs, only use dune pkg

## Testing CLI help output
- Use `--help=plain` to get non-interactive help output (avoids pager/man): `dune exec --root . epi -- launch --help=plain`
- Without `=plain`, the help command opens a pager and hangs in non-interactive contexts

## Testing against a real VM
- Create a VM yourself, e.g. `dune exec --root . epi -- launch <UNIQUE_INSTANCE_NAME> --target '.#manual-test'`
- Rebuild as necessary when changing the nix configuration, but avoid rebuilds if not to save time.
- SSH keys are auto-generated during provisioning
- Execute commands in VM, e.g. `dune exec epi -- exec test1 -- ls /`
- When done testing, remove the VM `dune exec epi -- rm -f test1`

## Instance state
- State is stored in `.epi/state/` (relative to project root), NOT `~/.local/state/epi/`
- Set via `EPI_STATE_DIR` env var in the dev environment

## Working in git worktrees
- Worktrees are created at `.claude/worktrees/<name>/` (nested inside the project root)
- Worktrees must be created from HEAD if there's a .jj directory in the main project
- A branch must be created on initialization
- Working with `dune` in a worktree requires passing `--root .`. e.g. `dune build --root .` or `dune pkg lock --root .`
- Initialize the worktree by running `dune build --root .`
- Always build, explore, and run commands in the worktree directory — never in the parent project root
- When searching/reading files, use the worktree path, not the parent repo path
- dune uses the OUTERMOST `dune-workspace`, so running `dune build` from a worktree picks up the parent workspace and fails with "No rule found for alias .claude/worktrees/.../default"
- Workaround: use `dune build --root .` (and `dune exec --root . epi -- ...`, `dune test --root .`) when working in a worktree
