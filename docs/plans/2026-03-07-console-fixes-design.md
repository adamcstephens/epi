# Console Fixes Design

Date: 2026-03-07

## Problems

Two bugs in console access:

1. **Root login fails at console.** The NixOS config sets `users.users.root.initialHashedPassword = ""` (empty = no password), but cloud-init overrides this. When the generated user-data contains a `users:` block, cloud-init defaults to `disable_root: true`, which locks or replaces root's password regardless of what NixOS set in `/etc/shadow`.

2. **Ctrl-C exits console but kills cloud-hypervisor.** `run_detached` uses `Unix.create_process_env`, which inherits the parent's process group. Pressing Ctrl-C in the terminal sends SIGINT to the entire foreground process group, which includes cloud-hypervisor. The VM dies.

## Design

### Fix 1 — disable_root in cloud-init user-data (`vm_launch.ml`)

Add `disable_root: false` to the cloud-config header in `generate_user_data`. This tells cloud-init not to touch root's account, leaving the NixOS-configured empty password intact.

### Fix 2 — process group isolation (`process.ml`)

Replace `Unix.create_process_env` in `run_detached` with a manual fork/exec:

- `Unix.fork()` to create child
- In child: `Unix.setsid()` to start a new session (detaches from controlling terminal and process group), redirect fds, `Unix.execve`
- In parent: close the fds, return `{ pid }`

Cloud-hypervisor then lives in its own session and is immune to Ctrl-C in epi's terminal.

### Fix 3 — SIGINT handling in console loop (`vm_launch.ml`)

Install a `Sys.Signal_handle` for `Sys.sigint` before entering the `select` loop in `attach_console`. The handler sets a `ref bool` flag. After each `select` call, check the flag and exit the loop cleanly if set. Restore the previous signal handler on exit (both normal and exception paths).

This lets Ctrl-C detach from the console without crashing epi with an unhandled signal.

## Scope

Three focused changes, all in existing functions. No new modules, types, or dependencies.
