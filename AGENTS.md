## Code style
- Avoid abstractions
- Avoid wrapping single expressions in standalone functions
- No `unwrap()` outside of tests — propagate with `?` or `ok_or_else`
- Keep `Option`/`Result` as long as possible — don't collapse to sentinel values (e.g. `unwrap_or(0)` then `> 0`)
- Functions that can fail should return `Result`, not log-and-continue
- Avoid unsafe code, ask before adding.
- Format code with `just format`

## Dependencies
- Rust deps are in `.cargo-home` — read code from there for correct versions without needing the internet.
- *Always* ask before adding dependencies.

## Testing
- Always execute red/green TDD
- Ensure you run e2e tests at least once before finalizing
- Quick tests: `just test` (runs unit + CLI integration concurrently)
- Unit only: `just test-unit`
- CLI only: `just test-cli`
- E2E (requires real VM): `just test-e2e`
- E2E individual groups: `just test-e2e e2e-setup`. You *must* test e2e-setup first in order to force a rebuild before testing other e2e groups.
- When possible, manually test: e.g. `just run list`

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
- Build, explore, and run commands in the worktree directory — never the parent
- Search/read files using the worktree path
