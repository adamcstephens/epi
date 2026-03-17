## Agent workflow
- **IMPORTANT**: before you do anything else, run the `beans prime` command and heed its output.
- Always use red/green TDD when implementing

## Definition of done steps
- lints pass
- tests pass
- changelog updated
- wait for user confirmation
- ticket marked done
- code committed with all ticket changes included
  - Ticket ID in the body
  - Co-Authored-By line always included
  - Use jj commit, never git commit

## Code style
- Avoid abstractions
- Avoid wrapping single expressions in standalone functions
- No `unwrap()` outside of tests — propagate with `?` or `ok_or_else`
- Keep `Option`/`Result` as long as possible — don't collapse to sentinel values (e.g. `unwrap_or(0)` then `> 0`)
- Functions that can fail should return `Result`, not log-and-continue
- Avoid unsafe code, ask before adding.
- Format code with `just format`
- Always check code linting with `just lint`
- Construct structs with direct literal syntax (`Foo { field: value, .. }`) instead of builder patterns or multi-argument `new()` functions
- Canonicalize relative paths to absolute paths as early as possible

## Dependencies
- Rust deps are in `./.cargo-home` — read code from there for correct versions without needing the internet.
- *Always* ask before adding dependencies.
- When adding dependencies, *always* check the internet for the latest version

## Testing
- Ensure you run e2e tests at least once before finalizing
- Add e2e tests when adding new capability that affects runtime, prefer extension of existing tests
- Quick tests: `just test` (runs unit + CLI integration concurrently)
- Unit only: `just test`
- E2E (requires real VM): `just test-e2e`
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
