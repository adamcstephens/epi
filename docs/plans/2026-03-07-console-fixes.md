# Console Fixes Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix two console bugs: cloud-init locking root (preventing passwordless login) and Ctrl-C killing cloud-hypervisor when detaching from console.

**Architecture:** Three focused edits to existing functions — add `disable_root: false` to cloud-init user-data, replace `Unix.create_process_env` with fork+setsid+exec in `run_detached`, and install a SIGINT handler in `attach_console` that sets a flag checked in the select loop.

**Tech Stack:** OCaml, Unix module, dune. Build: `dune build`. Tests: `dune test`.

---

### Task 1: Fix cloud-init locking root

**Files:**
- Modify: `lib/vm_launch.ml` — `generate_user_data` function (line ~452)

The generated user-data has a `users:` block but no `disable_root` key. Cloud-init defaults `disable_root: true` when `users:` is present, overriding the NixOS-configured empty root password.

**Step 1: Confirm the bug in the current output**

Read the current `generate_user_data` in `lib/vm_launch.ml` and confirm the cloud-config header only has `#cloud-config\nusers:\n` — no `disable_root` line.

**Step 2: Add `disable_root: false` to the header**

In `generate_user_data`, change the first buffer add from:
```ocaml
Buffer.add_string buf "#cloud-config\nusers:\n";
```
to:
```ocaml
Buffer.add_string buf "#cloud-config\ndisable_root: false\nusers:\n";
```

**Step 3: Build to verify no compile errors**

```bash
dune build
```
Expected: clean build, no errors.

**Step 4: Manual verification**

After building, run `epi up` against a target and check the staging dir:
```bash
cat ~/.local/state/epi/runtime/default.cidata/user-data
```
Expected: file contains `disable_root: false` on the second line.

**Step 5: Commit**

```bash
git add lib/vm_launch.ml
git commit -m "fix: disable_root false in cloud-init user-data to allow root console login"
```

---

### Task 2: Fix process group — cloud-hypervisor survives Ctrl-C

**Files:**
- Modify: `lib/process.ml` — `run_detached` function (line ~49)

`Unix.create_process_env` inherits the parent's process group. Ctrl-C sends SIGINT to the entire foreground process group, killing cloud-hypervisor. Fix: fork manually, call `Unix.setsid()` in child to create a new session, then exec.

**Step 1: Write a failing test**

In `test/test_epi.ml`, add a test at the bottom (before any final `;;` or after the last `run_test` call) that verifies a detached process survives SIGINT to the parent's process group:

```ocaml
let test_detached_process_survives_sigint ~bin () =
  (* Launch a sleep process via epi infrastructure — use /bin/sleep as a proxy.
     We test the process group property by checking the child PID stays alive
     after we send SIGINT to our own process group. *)
  (* Since run_detached is internal, we test indirectly:
     launch epi up with a fake resolver that sleeps, send SIGINT to our pgrp,
     check the child pid is still alive. *)
  (* Simpler proxy test: fork + setsid in shell, verify pgid differs *)
  let tmp_stdout = Filename.temp_file "epi_test" ".stdout" in
  let tmp_stderr = Filename.temp_file "epi_test" ".stderr" in
  Fun.protect
    ~finally:(fun () ->
      (try Unix.unlink tmp_stdout with _ -> ());
      (try Unix.unlink tmp_stderr with _ -> ()))
    (fun () ->
      (* Use shell to check: setsid python -c "import os; print(os.getpgid(0))" *)
      (* We can verify that run_detached creates a child in a different pgid
         by checking /proc/<pid>/stat after launch.
         For now, test that epi's architecture passes a smoke test: the binary
         builds and run_detached exists. Full integration test is manual. *)
      ignore (tmp_stdout, tmp_stderr))
```

Actually — the `run_detached` function is internal to the library and not directly testable via the CLI binary. Skip the automated test for this fix; verify manually in Task 2 Step 5.

**Step 1 (revised): Replace `run_detached` implementation**

Replace the entire `run_detached` function in `lib/process.ml`. Current implementation (lines 49–74):

```ocaml
let run_detached ?(env = Unix.environment ()) ~prog ~args ~stdout_path
    ~stderr_path () =
  ensure_parent_dir stdout_path;
  ensure_parent_dir stderr_path;
  let argv = Array.of_list (prog :: args) in
  let stdin_fd = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
  let stdout_fd =
    Unix.openfile stdout_path
      [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ]
      0o644
  in
  let stderr_fd =
    Unix.openfile stderr_path
      [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ]
      0o644
  in
  Fun.protect
    ~finally:(fun () ->
      Unix.close stdin_fd;
      Unix.close stdout_fd;
      Unix.close stderr_fd)
    (fun () ->
      let pid =
        Unix.create_process_env prog argv env stdin_fd stdout_fd stderr_fd
      in
      { pid })
```

Replace with:

```ocaml
let run_detached ?(env = Unix.environment ()) ~prog ~args ~stdout_path
    ~stderr_path () =
  ensure_parent_dir stdout_path;
  ensure_parent_dir stderr_path;
  let argv = Array.of_list (prog :: args) in
  let stdin_fd = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
  let stdout_fd =
    Unix.openfile stdout_path
      [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ]
      0o644
  in
  let stderr_fd =
    Unix.openfile stderr_path
      [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ]
      0o644
  in
  let pid = Unix.fork () in
  if pid = 0 then (
    let _ = Unix.setsid () in
    Unix.dup2 stdin_fd Unix.stdin;
    Unix.dup2 stdout_fd Unix.stdout;
    Unix.dup2 stderr_fd Unix.stderr;
    Unix.close stdin_fd;
    Unix.close stdout_fd;
    Unix.close stderr_fd;
    (try Unix.execve prog argv env with _ -> exit 127))
  else (
    Unix.close stdin_fd;
    Unix.close stdout_fd;
    Unix.close stderr_fd;
    { pid })
```

Key differences:
- `Unix.fork()` instead of `Unix.create_process_env`
- Child calls `Unix.setsid()` to detach from the terminal's process group and create a new session
- Child redirects fds with `dup2`, closes originals, then `Unix.execve`
- Parent closes fds and returns `{ pid }`
- `execve` failure in child exits with 127 (standard "command not found" convention)

**Step 2: Build**

```bash
dune build
```
Expected: clean build.

**Step 3: Verify PGID isolation manually**

Start a VM:
```bash
dune exec epi -- up --target .#manual-test
```

Get the pid from the output, then check its process group:
```bash
cat /proc/<pid>/stat | awk '{print $5}'  # field 5 is pgrp
echo $$  # epi's parent shell pgrp
```
Expected: the cloud-hypervisor pgrp differs from the shell's pgrp.

**Step 4: Commit**

```bash
git add lib/process.ml
git commit -m "fix: setsid in run_detached so cloud-hypervisor is immune to Ctrl-C in terminal"
```

---

### Task 3: Handle SIGINT in attach_console for clean exit

**Files:**
- Modify: `lib/vm_launch.ml` — `attach_console` function (line ~717)

When Ctrl-C is pressed, SIGINT is delivered to epi. Without a handler, epi dies with an unhandled signal. With cloud-hypervisor now in its own session (Task 2), epi is the only process that gets it — but it still crashes ungracefully. Install a handler that sets a flag; the select loop checks the flag and exits cleanly.

**Step 1: Add interrupted ref and SIGINT handler before the select loop**

Inside `attach_console`, find the `try` block that starts the `loop` (around line 782). Just before it, add the signal setup. The function currently looks like:

```ocaml
      try
        let rec loop read_stdin =
          ...
        in
        loop read_stdin;
```

Change to:

```ocaml
      let interrupted = ref false in
      let old_sigint =
        Sys.signal Sys.sigint (Sys.Signal_handle (fun _ -> interrupted := true))
      in
      let restore_sigint () = Sys.set_signal Sys.sigint old_sigint in
      try
        let rec loop read_stdin =
```

**Step 2: Check the flag after each select call**

Inside the loop, after the `Unix.select` call and the timeout check, add an interrupted check. The current code after select is:

```ocaml
              if
                ready = []
                && match deadline with Some _ -> true | None -> false
              then
                raise
                  (Failure ...);
```

Add after that block (before the `let read_stdin =` line):

```ocaml
              if !interrupted then raise Exit;
```

**Step 3: Restore the signal handler in all exit paths**

After `loop read_stdin;` and before `Ok ()`, add `restore_sigint ()`. The clean-exit path becomes:

```ocaml
            loop read_stdin;
            restore_sigint ();
            close_capture_channel capture_channel_opt;
            close_socket ();
            Ok ()
```

Add `restore_sigint ()` at the start of each `with` handler too:

```ocaml
          with
          | Exit ->
              restore_sigint ();
              close_capture_channel capture_channel_opt;
              close_socket ();
              Ok ()
          | Failure message when contains message "console timeout reached" ->
              restore_sigint ();
              close_capture_channel capture_channel_opt;
              close_socket ();
              Error (Console_session_timed_out ...)
          | Unix.Unix_error (error, _, _) ->
              restore_sigint ();
              close_capture_channel capture_channel_opt;
              close_socket ();
              Error (Serial_endpoint_unavailable ...)
```

**Step 4: Build**

```bash
dune build
```
Expected: clean build.

**Step 5: Run existing tests**

```bash
dune test
```
Expected: all tests pass.

**Step 6: Manual test — Ctrl-C detaches without killing VM**

```bash
dune exec epi -- up --target .#manual-test --console
# Once console is attached, press Ctrl-C
```
Expected:
- Console session ends, epi exits cleanly (exit 0 or with a short message)
- `epi list` still shows the instance as running
- `epi console` can re-attach

**Step 7: Commit**

```bash
git add lib/vm_launch.ml
git commit -m "fix: handle SIGINT in attach_console to detach cleanly without crashing"
```

---

### Task 4: End-to-end manual test

**Step 1: Remove any stale instance**

```bash
dune exec epi -- rm --force default 2>/dev/null || true
```

**Step 2: Launch and attach console, try root login**

```bash
dune exec epi -- up --target .#manual-test --console
```

At the `manual-test login:` prompt, type `root` and press Enter. At `Password:`, press Enter (empty). Expected: logs in as root.

**Step 3: Detach with Ctrl-C, verify VM lives**

Press Ctrl-C at the console. Expected: epi exits cleanly.

```bash
dune exec epi -- list
```
Expected: `default` instance still listed.

**Step 4: Re-attach console**

```bash
dune exec epi -- console
```
Expected: attaches to the running VM's serial output.
