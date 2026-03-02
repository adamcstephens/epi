type state_entry = {
  instance_name : string;
  target : string;
  pid : int option;
  serial_socket : string option;
  disk : string option;
}

let contains text snippet =
  let text_len = String.length text in
  let snippet_len = String.length snippet in
  if snippet_len = 0 then true
  else
    let rec loop i =
      if i + snippet_len > text_len then false
      else if String.sub text i snippet_len = snippet then true
      else loop (i + 1)
    in
    loop 0

let read_all channel =
  let buffer = Buffer.create 128 in
  let rec loop () =
    match input_line channel with
    | line ->
        Buffer.add_string buffer line;
        Buffer.add_char buffer '\n';
        loop ()
    | exception End_of_file -> Buffer.contents buffer
  in
  loop ()

let run_cli_with_env ~bin ~state_file ~extra_env args =
  let env_entries =
    ("EPI_STATE_FILE", state_file) :: extra_env
    |> List.map (fun (key, value) -> Printf.sprintf "%s=%s" key value)
    |> Array.of_list
  in
  let env = Array.append (Unix.environment ()) env_entries in
  let argv = Array.of_list (bin :: args) in
  let stdout_channel, stdin_channel, stderr_channel =
    Unix.open_process_args_full bin argv env
  in
  close_out stdin_channel;
  let stdout = read_all stdout_channel in
  let stderr = read_all stderr_channel in
  let exit_code =
    match
      Unix.close_process_full (stdout_channel, stdin_channel, stderr_channel)
    with
    | Unix.WEXITED code -> code
    | Unix.WSIGNALED signal -> 128 + signal
    | Unix.WSTOPPED signal -> 128 + signal
  in
  (exit_code, stdout, stderr)

let run_cli ~bin ~state_file args =
  run_cli_with_env ~bin ~state_file ~extra_env:[] args

let fail fmt = Printf.ksprintf (fun message -> raise (Failure message)) fmt

let assert_success ~context (code, _stdout, stderr) =
  if code <> 0 then
    fail "%s: expected success, got exit=%d stderr=%S" context code stderr

let assert_failure ~context (code, _stdout, _stderr) =
  if code = 0 then fail "%s: expected non-zero exit status" context

let assert_contains ~context text snippet =
  if not (contains text snippet) then
    fail "%s: expected to find %S in:\n%s" context snippet text

let run_test ~name f =
  try
    f ();
    Printf.printf "ok - %s\n%!" name
  with Failure message ->
    Printf.eprintf "not ok - %s\n%s\n%!" name message;
    exit 1

let parse_state_line line =
  let fields = String.split_on_char '\t' line in
  let parse_runtime pid_text serial_socket disk =
    let pid =
      match int_of_string_opt pid_text with
      | Some value when value > 0 -> Some value
      | _ -> None
    in
    let serial_socket =
      if serial_socket = "" then None else Some serial_socket
    in
    let disk = if disk = "" then None else Some disk in
    (pid, serial_socket, disk)
  in
  match fields with
  | [ instance_name; target ] ->
      Some
        { instance_name; target; pid = None; serial_socket = None; disk = None }
  | [ instance_name; target; pid_text; serial_socket; disk ] ->
      let pid, serial_socket, disk =
        parse_runtime pid_text serial_socket disk
      in
      Some { instance_name; target; pid; serial_socket; disk }
  | _ -> None

let read_state_entries path =
  if not (Sys.file_exists path) then []
  else
    let channel = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in channel)
      (fun () ->
        let rec loop acc =
          match input_line channel with
          | line -> (
              match parse_state_line line with
              | Some entry -> loop (entry :: acc)
              | None -> loop acc)
          | exception End_of_file -> List.rev acc
        in
        loop [])

let find_state_entry path instance_name =
  read_state_entries path
  |> List.find_opt (fun entry -> String.equal entry.instance_name instance_name)

let assert_missing_state_entry ~context path instance_name =
  match find_state_entry path instance_name with
  | None -> ()
  | Some _ ->
      fail "%s: expected state entry %S to be removed" context instance_name

let pid_is_alive pid =
  try
    Unix.kill pid 0;
    true
  with
  | Unix.Unix_error (Unix.ESRCH, _, _) -> false
  | Unix.Unix_error (Unix.EPERM, _, _) -> true

let terminate_pid pid =
  (if pid_is_alive pid then
     try Unix.kill pid Sys.sigterm with Unix.Unix_error _ -> ());
  try ignore (Unix.waitpid [ Unix.WNOHANG ] pid)
  with Unix.Unix_error (Unix.ECHILD, _, _) -> ()

let cleanup_state_pids path =
  read_state_entries path
  |> List.iter (fun entry ->
      match entry.pid with Some pid -> terminate_pid pid | None -> ())

let with_state_file f =
  let path = Filename.temp_file "epi-cli-test" ".tsv" in
  Sys.remove path;
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists path then cleanup_state_pids path;
      if Sys.file_exists path then Sys.remove path)
    (fun () -> f path)

let with_temp_dir prefix f =
  let base =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (prefix ^ string_of_int (Unix.getpid ()))
  in
  let rec find_free n =
    let candidate = if n = 0 then base else base ^ "-" ^ string_of_int n in
    if Sys.file_exists candidate then find_free (n + 1) else candidate
  in
  let dir = find_free 0 in
  Unix.mkdir dir 0o755;
  let rec remove_tree path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Sys.readdir path
        |> Array.iter (fun name -> remove_tree (Filename.concat path name));
        Unix.rmdir path)
      else Sys.remove path
  in
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () -> f dir)

let write_file path content =
  let channel = open_out path in
  output_string channel content;
  close_out channel

let write_state_entry path entry =
  let channel =
    open_out_gen [ Open_creat; Open_wronly; Open_append ] 0o644 path
  in
  let pid =
    match entry.pid with Some value -> string_of_int value | None -> ""
  in
  let serial_socket =
    match entry.serial_socket with Some value -> value | None -> ""
  in
  let disk = match entry.disk with Some value -> value | None -> "" in
  output_string channel
    (String.concat "\t"
       [ entry.instance_name; entry.target; pid; serial_socket; disk ]);
  output_char channel '\n';
  close_out channel

let write_legacy_pid_state_entry path ~instance_name ~target ~pid =
  let channel =
    open_out_gen [ Open_creat; Open_wronly; Open_append ] 0o644 path
  in
  output_string channel
    (String.concat "\t" [ instance_name; target; string_of_int pid ]);
  output_char channel '\n';
  close_out channel

let make_executable path = Unix.chmod path 0o755

let with_mock_runtime f =
  with_temp_dir "epi-vm-test" (fun dir ->
      let kernel = Filename.concat dir "vmlinuz" in
      let disk = Filename.concat dir "disk.img" in
      let initrd = Filename.concat dir "initrd.img" in
      let resolver = Filename.concat dir "resolver.sh" in
      let cloud_hypervisor = Filename.concat dir "cloud-hypervisor.sh" in
      let launch_log = Filename.concat dir "launch.log" in
      write_file kernel "kernel";
      write_file disk "disk";
      write_file initrd "initrd";
      write_file resolver
        ("#!/usr/bin/env sh\n\
          if [ \"$EPI_TARGET\" = \".#fail-resolve\" ]; then\n\
         \  echo \"resolver exploded\" >&2\n\
         \  exit 21\n\
          fi\n\
          if [ \"$EPI_TARGET\" = \".#missing-disk\" ]; then\n\
         \  echo \"kernel=" ^ kernel
       ^ "\"\n\
         \  echo \"cpus=2\"\n\
         \  echo \"memory_mib=1024\"\n\
         \  exit 0\n\
          fi\n\
          echo \"kernel=" ^ kernel ^ "\"\necho \"disk=" ^ disk
       ^ "\"\necho \"initrd=" ^ initrd
       ^ "\"\necho \"cpus=2\"\necho \"memory_mib=1536\"\n");
      write_file cloud_hypervisor
        ("#!/usr/bin/env sh\necho \"$*\" >> \"" ^ launch_log
       ^ "\"\n\
          if [ \"$EPI_FORCE_LAUNCH_FAIL\" = \"1\" ]; then\n\
         \  echo \"mock launch failed\" >&2\n\
         \  exit 12\n\
          fi\n\
          if [ \"$EPI_FORCE_LOCK_FAIL\" = \"1\" ]; then\n\
         \  echo \"disk lock conflict: Resource temporarily unavailable\" >&2\n\
         \  exit 23\n\
          fi\n\
          exec sleep \"${EPI_MOCK_VM_SLEEP:-30}\"\n");
      make_executable resolver;
      make_executable cloud_hypervisor;
      let extra_env =
        [
          ("EPI_TARGET_RESOLVER_CMD", resolver);
          ("EPI_CLOUD_HYPERVISOR_BIN", cloud_hypervisor);
          ("EPI_MOCK_VM_SLEEP", "30");
        ]
      in
      f ~extra_env ~launch_log ~disk)

let with_sleep_process f =
  match Unix.fork () with
  | 0 ->
      Unix.sleep 30;
      exit 0
  | pid -> Fun.protect ~finally:(fun () -> terminate_pid pid) (fun () -> f pid)

let () =
  let bin =
    if Array.length Sys.argv < 2 then
      failwith "Expected path to epi binary as argv[1]"
    else Sys.argv.(1)
  in
  run_test ~name:"up provisions explicit and implicit default instances"
    (fun () ->
      with_mock_runtime (fun ~extra_env ~launch_log ~disk:_ ->
          with_state_file (fun state_file ->
              let explicit =
                run_cli_with_env ~bin ~state_file ~extra_env
                  [ "up"; "dev-a"; "--target"; ".#dev-a" ]
              in
              assert_success ~context:"explicit up" explicit;
              let _, stdout_explicit, _ = explicit in
              assert_contains ~context:"explicit up output" stdout_explicit
                "up: provisioned instance=dev-a target=.#dev-a pid=";
              assert_contains ~context:"explicit up output" stdout_explicit
                "serial=";
              let implicit =
                run_cli_with_env ~bin ~state_file ~extra_env
                  [ "up"; "--target"; "github:org/repo#dev" ]
              in
              assert_success ~context:"implicit up" implicit;
              let _, stdout_implicit, _ = implicit in
              assert_contains ~context:"implicit up output" stdout_implicit
                "up: provisioned instance=default target=github:org/repo#dev \
                 pid=";
              let launch_contents =
                if Sys.file_exists launch_log then
                  let channel = open_in launch_log in
                  Fun.protect
                    ~finally:(fun () -> close_in channel)
                    (fun () -> read_all channel)
                else ""
              in
              assert_contains ~context:"launch invocation log" launch_contents
                "--serial";
              assert_contains ~context:"launch invocation log" launch_contents
                "socket=";
              let dev_a = find_state_entry state_file "dev-a" in
              (match dev_a with
              | Some { pid = Some _; serial_socket = Some _; _ } -> ()
              | _ -> fail "expected runtime metadata for dev-a");
              let default = find_state_entry state_file "default" in
              (match default with
              | Some { pid = Some _; serial_socket = Some _; _ } -> ()
              | _ -> fail "expected runtime metadata for default");
              let status_default =
                run_cli_with_env ~bin ~state_file ~extra_env [ "status" ]
              in
              assert_success ~context:"status default" status_default;
              let _, status_out, _ = status_default in
              assert_contains ~context:"status default output" status_out
                "status: instance=default")));
  run_test ~name:"up rejects invalid target formats with actionable errors"
    (fun () ->
      with_state_file (fun state_file ->
          let missing_separator =
            run_cli ~bin ~state_file [ "up"; "dev-a"; "--target"; "." ]
          in
          assert_failure ~context:"missing separator" missing_separator;
          let _, _, err1 = missing_separator in
          assert_contains ~context:"missing separator error" err1
            "--target must use <flake-ref>#<config-name>";
          let missing_config =
            run_cli ~bin ~state_file [ "up"; "dev-a"; "--target"; ".#" ]
          in
          assert_failure ~context:"missing config" missing_config;
          let _, _, err2 = missing_config in
          assert_contains ~context:"missing config error" err2
            "both flake reference and config name are required"));
  run_test ~name:"up does not persist instance when provisioning fails"
    (fun () ->
      with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
          with_state_file (fun state_file ->
              let failing_env = ("EPI_FORCE_LAUNCH_FAIL", "1") :: extra_env in
              let failed =
                run_cli_with_env ~bin ~state_file ~extra_env:failing_env
                  [ "up"; "qa-1"; "--target"; ".#qa" ]
              in
              assert_failure ~context:"failing up" failed;
              let _, _, err = failed in
              assert_contains ~context:"launch failure error" err
                "VM launch failed";
              let listed =
                run_cli_with_env ~bin ~state_file ~extra_env [ "list" ]
              in
              assert_success ~context:"list after failed up" listed;
              let _, listed_out, _ = listed in
              if contains listed_out "qa-1" then
                fail "instance was unexpectedly persisted after launch failure")));
  run_test ~name:"up reports target resolution failures with target context"
    (fun () ->
      with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
          with_state_file (fun state_file ->
              let failed =
                run_cli_with_env ~bin ~state_file ~extra_env
                  [ "up"; "dev-a"; "--target"; ".#fail-resolve" ]
              in
              assert_failure ~context:"target resolution failure" failed;
              let _, _, err = failed in
              assert_contains ~context:"resolution failure stage" err
                "target resolution failed";
              assert_contains ~context:"resolution failure target" err
                ".#fail-resolve")));
  run_test ~name:"up validates launch inputs before VM launch" (fun () ->
      with_mock_runtime (fun ~extra_env ~launch_log ~disk:_ ->
          with_state_file (fun state_file ->
              let failed =
                run_cli_with_env ~bin ~state_file ~extra_env
                  [ "up"; "dev-a"; "--target"; ".#missing-disk" ]
              in
              assert_failure ~context:"missing disk failure" failed;
              let _, _, err = failed in
              assert_contains ~context:"missing input stage" err
                "descriptor validation failed";
              assert_contains ~context:"missing input error" err
                "missing launch input: disk";
              let launch_contents =
                if Sys.file_exists launch_log then
                  let channel = open_in launch_log in
                  Fun.protect
                    ~finally:(fun () -> close_in channel)
                    (fun () -> read_all channel)
                else ""
              in
              if String.length launch_contents > 0 then
                fail "cloud-hypervisor was invoked despite missing launch input")));
  run_test ~name:"up reports disk lock conflicts with tracked owner metadata"
    (fun () ->
      with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk ->
          with_state_file (fun state_file ->
              let owner_up =
                run_cli_with_env ~bin ~state_file ~extra_env
                  [ "up"; "dev-owner"; "--target"; ".#owner" ]
              in
              assert_success ~context:"owner up" owner_up;
              let owner_pid =
                match find_state_entry state_file "dev-owner" with
                | Some { pid = Some pid; _ } -> pid
                | _ -> fail "missing owner runtime metadata"
              in
              let failing_env = ("EPI_FORCE_LOCK_FAIL", "1") :: extra_env in
              let failed =
                run_cli_with_env ~bin ~state_file ~extra_env:failing_env
                  [ "up"; "qa-1"; "--target"; ".#qa" ]
              in
              assert_failure ~context:"lock failure" failed;
              let _, _, err = failed in
              assert_contains ~context:"lock conflict stage" err
                "another running VM already holds disk lock";
              assert_contains ~context:"lock conflict owner" err
                "owner=dev-owner";
              assert_contains ~context:"lock conflict pid" err
                (string_of_int owner_pid);
              assert_contains ~context:"lock conflict disk" err disk)));
  run_test ~name:"console reports not-running instances with guidance"
    (fun () ->
      with_state_file (fun state_file ->
          write_state_entry state_file
            {
              instance_name = "dev-a";
              target = ".#dev-a";
              pid = None;
              serial_socket = None;
              disk = None;
            };
          let result = run_cli ~bin ~state_file [ "console"; "dev-a" ] in
          assert_failure ~context:"console not running" result;
          let _, _, err = result in
          assert_contains ~context:"console not running message" err
            "Instance 'dev-a' is not running";
          assert_contains ~context:"console not running guidance" err
            "epi up dev-a --target"));
  run_test ~name:"console treats legacy pid state rows as running metadata"
    (fun () ->
      with_state_file (fun state_file ->
          with_sleep_process (fun pid ->
              write_legacy_pid_state_entry state_file ~instance_name:"legacy"
                ~target:".#legacy" ~pid;
              let result = run_cli ~bin ~state_file [ "console"; "legacy" ] in
              assert_failure ~context:"console legacy pid row" result;
              let _, _, err = result in
              assert_contains ~context:"console legacy pid row message" err
                "Serial endpoint unavailable for 'legacy'")));
  run_test
    ~name:"console reports unavailable serial endpoint for running instance"
    (fun () ->
      with_state_file (fun state_file ->
          with_sleep_process (fun pid ->
              write_state_entry state_file
                {
                  instance_name = "dev-a";
                  target = ".#dev-a";
                  pid = Some pid;
                  serial_socket = Some "/tmp/epi-nonexistent.sock";
                  disk = Some "/tmp/disk.img";
                };
              let result = run_cli ~bin ~state_file [ "console"; "dev-a" ] in
              assert_failure ~context:"console unavailable endpoint" result;
              let _, _, err = result in
              assert_contains ~context:"console unavailable message" err
                "Serial endpoint unavailable for 'dev-a'";
              assert_contains ~context:"console unavailable guidance" err
                "Check VM runtime state for 'dev-a'")));
  run_test
    ~name:"startup reconciliation clears stale runtime and keeps active runtime"
    (fun () ->
      with_state_file (fun state_file ->
          with_temp_dir "epi-reconcile-test" (fun dir ->
              with_sleep_process (fun live_pid ->
                  write_state_entry state_file
                    {
                      instance_name = "stale";
                      target = ".#stale";
                      pid = Some 999_999;
                      serial_socket = Some (Filename.concat dir "stale.sock");
                      disk = Some "/tmp/stale-disk.img";
                    };
                  write_state_entry state_file
                    {
                      instance_name = "live";
                      target = ".#live";
                      pid = Some live_pid;
                      serial_socket = Some (Filename.concat dir "live.sock");
                      disk = Some "/tmp/live-disk.img";
                    };
                  let listed = run_cli ~bin ~state_file [ "list" ] in
                  assert_success ~context:"list with reconciliation" listed;
                  let stale = find_state_entry state_file "stale" in
                  (match stale with
                  | Some { pid = None; _ } -> ()
                  | _ -> fail "expected stale runtime metadata to be cleared");
                  let live = find_state_entry state_file "live" in
                  match live with
                  | Some { pid = Some pid; _ } when pid = live_pid -> ()
                  | _ -> fail "expected live runtime metadata to remain active"))));
  run_test ~name:"rm removes stopped instances from state" (fun () ->
      with_state_file (fun state_file ->
          write_state_entry state_file
            {
              instance_name = "dev-a";
              target = ".#dev-a";
              pid = None;
              serial_socket = None;
              disk = None;
            };
          let removed = run_cli ~bin ~state_file [ "rm"; "dev-a" ] in
          assert_success ~context:"rm stopped instance" removed;
          let _, out, _ = removed in
          assert_contains ~context:"rm stopped output" out
            "rm: removed instance=dev-a";
          assert_missing_state_entry ~context:"rm stopped state cleanup"
            state_file "dev-a"));
  run_test ~name:"rm refuses to remove running instance without --force"
    (fun () ->
      with_state_file (fun state_file ->
          with_sleep_process (fun pid ->
              write_state_entry state_file
                {
                  instance_name = "dev-a";
                  target = ".#dev-a";
                  pid = Some pid;
                  serial_socket = Some "/tmp/dev-a.serial.sock";
                  disk = Some "/tmp/dev-a.disk";
                };
              let rejected = run_cli ~bin ~state_file [ "rm"; "dev-a" ] in
              assert_failure ~context:"rm running without force" rejected;
              let _, _, err = rejected in
              assert_contains ~context:"rm running rejection message" err
                "Instance 'dev-a' is running";
              assert_contains ~context:"rm running rejection guidance" err
                "use `epi rm --force dev-a`";
              match find_state_entry state_file "dev-a" with
              | Some { pid = Some active_pid; _ } when active_pid = pid -> ()
              | _ -> fail "expected running instance to remain in state")));
  run_test ~name:"rm --force terminates running instance before removing"
    (fun () ->
      with_state_file (fun state_file ->
          with_sleep_process (fun pid ->
              write_state_entry state_file
                {
                  instance_name = "dev-a";
                  target = ".#dev-a";
                  pid = Some pid;
                  serial_socket = Some "/tmp/dev-a.serial.sock";
                  disk = Some "/tmp/dev-a.disk";
                };
              let removed =
                run_cli ~bin ~state_file [ "rm"; "--force"; "dev-a" ]
              in
              assert_success ~context:"rm force running" removed;
              let _, out, _ = removed in
              assert_contains ~context:"rm force output" out
                "rm: removed instance=dev-a";
              assert_missing_state_entry ~context:"rm force state cleanup"
                state_file "dev-a")));
  run_test ~name:"rm --force reports termination errors and keeps state"
    (fun () ->
      if Unix.geteuid () = 0 then ()
      else
        with_state_file (fun state_file ->
            write_state_entry state_file
              {
                instance_name = "protected";
                target = ".#protected";
                pid = Some 1;
                serial_socket = Some "/tmp/protected.serial.sock";
                disk = Some "/tmp/protected.disk";
              };
            let failed =
              run_cli ~bin ~state_file [ "rm"; "--force"; "protected" ]
            in
            assert_failure ~context:"rm force termination failure" failed;
            let _, _, err = failed in
            assert_contains ~context:"rm force termination failure output" err
              "failed to terminate";
            match find_state_entry state_file "protected" with
            | Some { pid = Some 1; _ } -> ()
            | _ -> fail "expected entry to remain after failed force removal"));
  run_test ~name:"list shows empty and multi-instance state" (fun () ->
      with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
          with_state_file (fun state_file ->
              let empty =
                run_cli_with_env ~bin ~state_file ~extra_env [ "list" ]
              in
              assert_success ~context:"list empty" empty;
              let _, empty_out, _ = empty in
              assert_contains ~context:"list empty output" empty_out
                "No instances found.";
              ignore
                (run_cli_with_env ~bin ~state_file ~extra_env
                   [ "up"; "--target"; ".#default" ]);
              ignore
                (run_cli_with_env ~bin ~state_file ~extra_env
                   [ "up"; "qa-1"; "--target"; "github:org/repo#qa-1" ]);
              let listed =
                run_cli_with_env ~bin ~state_file ~extra_env [ "list" ]
              in
              assert_success ~context:"list multi" listed;
              let _, listed_out, _ = listed in
              assert_contains ~context:"list header" listed_out
                "INSTANCE\tTARGET";
              assert_contains ~context:"list default row" listed_out
                "default\t.#default";
              assert_contains ~context:"list qa row" listed_out
                "qa-1\tgithub:org/repo#qa-1")));
  ()
