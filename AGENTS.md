## Agent workflow
- Use `bd` for task tracking
- Always use red/green TDD when implementing

## Code style
- Avoid abstractions
- Avoid wrapping single expressions in standalone functions
- No `unwrap()` outside of tests — propagate with `?` or `ok_or_else`
- Keep `Option`/`Result` as long as possible — don't collapse to sentinel values (e.g. `unwrap_or(0)` then `> 0`)
- Functions that can fail should return `Result`, not log-and-continue
- Avoid unsafe code, ask before adding.
- Format code with `just format`
- Always check code linting with `just lint`
- Canonicalize relative paths to absolute paths as early as possible

## Dependencies
- Rust deps are in `.cargo-home` — read code from there for correct versions without needing the internet.
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

<!-- BEGIN BEADS INTEGRATION -->
## Issue Tracking with bd (beads)

**IMPORTANT**: This project uses **bd (beads)** for ALL issue tracking. Do NOT use markdown TODOs, task lists, or other tracking methods.

### Why bd?

- Dependency-aware: Track blockers and relationships between issues
- Git-friendly: Dolt-powered version control with native sync
- Agent-optimized: JSON output, ready work detection, discovered-from links
- Prevents duplicate tracking systems and confusion

### Quick Start

**Check for ready work:**

```bash
bd ready --json
```

**Create new issues:**

```bash
bd create "Issue title" --description="Detailed context" -t bug|feature|task -p 0-4 --json
bd create "Issue title" --description="What this issue is about" -p 1 --deps discovered-from:bd-123 --json
```

**Claim and update:**

```bash
bd update <id> --claim --json
bd update bd-42 --priority 1 --json
```

**Complete work:**

```bash
bd close bd-42 --reason "Completed" --json
```

### Issue Types

- `bug` - Something broken
- `feature` - New functionality
- `task` - Work item (tests, docs, refactoring)
- `epic` - Large feature with subtasks
- `chore` - Maintenance (dependencies, tooling)

### Priorities

- `0` - Critical (security, data loss, broken builds)
- `1` - High (major features, important bugs)
- `2` - Medium (default, nice-to-have)
- `3` - Low (polish, optimization)
- `4` - Backlog (future ideas)

### Workflow for AI Agents

1. **Check ready work**: `bd ready` shows unblocked issues
2. **Claim your task atomically**: `bd update <id> --claim`
3. **Work on it**: Implement, test, document
4. **Discover new work?** Create linked issue:
   - `bd create "Found bug" --description="Details about what was found" -p 1 --deps discovered-from:<parent-id>`
5. **Complete**: `bd close <id> --reason "Done"`

### Auto-Sync

bd automatically syncs via Dolt:

- Each write auto-commits to Dolt history
- Use `bd dolt push`/`bd dolt pull` for remote sync
- No manual export/import needed!

### Important Rules

- ✅ Use bd for ALL task tracking
- ✅ Always use `--json` flag for programmatic use
- ✅ Link discovered work with `discovered-from` dependencies
- ✅ Check `bd ready` before asking "what should I work on?"
- ❌ Do NOT create markdown TODO lists
- ❌ Do NOT use external issue trackers
- ❌ Do NOT duplicate tracking systems

For more details, see README.md and docs/QUICKSTART.md.

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Update CHANGELOG.md** - Document the change in a single line, high-level, description. Note breaking changes.
5. **Commit all work** - Everything must be committed (use jj)
6. **Sync beads** - `bd dolt pull` to sync issue tracking
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until all changes are committed

<!-- END BEADS INTEGRATION -->
