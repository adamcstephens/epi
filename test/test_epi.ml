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

let wait_until_path_exists ~path ~attempts =
  let rec loop remaining =
    if Sys.file_exists path then true
    else if remaining <= 0 then false
    else
      let _ = Unix.select [] [] [] 0.01 in
      loop (remaining - 1)
  in
  loop attempts

let with_unix_socket_server ~socket_path ~payload f =
  let run_server () =
    if Sys.file_exists socket_path then Unix.unlink socket_path;
    let server = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    Fun.protect
      ~finally:(fun () ->
        (try Unix.close server with Unix.Unix_error _ -> ());
        if Sys.file_exists socket_path then Unix.unlink socket_path)
      (fun () ->
        Unix.bind server (Unix.ADDR_UNIX socket_path);
        Unix.listen server 1;
        let client, _ = Unix.accept server in
        Fun.protect
          ~finally:(fun () ->
            try Unix.close client with Unix.Unix_error _ -> ())
          (fun () ->
            let bytes = Bytes.of_string payload in
            ignore (Unix.write client bytes 0 (Bytes.length bytes))))
  in
  match Unix.fork () with
  | 0 ->
      run_server ();
      exit 0
  | pid ->
      if not (wait_until_path_exists ~path:socket_path ~attempts:200) then
        fail "socket server did not start for %s" socket_path;
      Fun.protect
        ~finally:(fun () ->
          terminate_pid pid;
          try ignore (Unix.waitpid [ Unix.WNOHANG ] pid)
          with Unix.Unix_error (Unix.ECHILD, _, _) -> ())
        f

let with_delayed_unix_socket_server ?(before_bind = fun () -> ()) ~socket_path
    ~payload f =
  let run_server () =
    before_bind ();
    let rec wait_until_bindable remaining =
      if remaining <= 0 then
        fail "socket server did not bind for %s" socket_path
      else
        let parent = Filename.dirname socket_path in
        if not (Sys.file_exists parent) then
          let _ = Unix.select [] [] [] 0.01 in
          wait_until_bindable (remaining - 1)
        else
          let server = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
          try
            Unix.bind server (Unix.ADDR_UNIX socket_path);
            server
          with Unix.Unix_error _ ->
            Unix.close server;
            let _ = Unix.select [] [] [] 0.01 in
            wait_until_bindable (remaining - 1)
    in
    let server = wait_until_bindable 400 in
    Fun.protect
      ~finally:(fun () ->
        (try Unix.close server with Unix.Unix_error _ -> ());
        if Sys.file_exists socket_path then Unix.unlink socket_path)
      (fun () ->
        Unix.listen server 1;
        let client, _ = Unix.accept server in
        Fun.protect
          ~finally:(fun () ->
            try Unix.close client with Unix.Unix_error _ -> ())
          (fun () ->
            let bytes = Bytes.of_string payload in
            ignore (Unix.write client bytes 0 (Bytes.length bytes))))
  in
  match Unix.fork () with
  | 0 ->
      run_server ();
      exit 0
  | pid ->
      Fun.protect
        ~finally:(fun () ->
          terminate_pid pid;
          try ignore (Unix.waitpid [ Unix.WNOHANG ] pid)
          with Unix.Unix_error (Unix.ECHILD, _, _) -> ())
        f

let with_hanging_unix_socket_server ~socket_path ~hold_seconds f =
  let run_server () =
    if Sys.file_exists socket_path then Unix.unlink socket_path;
    let server = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    Fun.protect
      ~finally:(fun () ->
        (try Unix.close server with Unix.Unix_error _ -> ());
        if Sys.file_exists socket_path then Unix.unlink socket_path)
      (fun () ->
        Unix.bind server (Unix.ADDR_UNIX socket_path);
        Unix.listen server 1;
        let client, _ = Unix.accept server in
        Fun.protect
          ~finally:(fun () ->
            try Unix.close client with Unix.Unix_error _ -> ())
          (fun () ->
            let _ = Unix.select [] [] [] hold_seconds in
            ()))
  in
  match Unix.fork () with
  | 0 ->
      run_server ();
      exit 0
  | pid ->
      if not (wait_until_path_exists ~path:socket_path ~attempts:200) then
        fail "hanging socket server did not start for %s" socket_path;
      Fun.protect
        ~finally:(fun () ->
          terminate_pid pid;
          try ignore (Unix.waitpid [ Unix.WNOHANG ] pid)
          with Unix.Unix_error (Unix.ECHILD, _, _) -> ())
        f

let with_mock_runtime f =
  with_temp_dir "epi-vm-test" (fun dir ->
      let kernel = Filename.concat dir "vmlinuz" in
      let disk = Filename.concat dir "disk.img" in
      let initrd = Filename.concat dir "initrd.img" in
      let mutable_disk_dir = Filename.concat dir "mutable" in
      let mutable_disk = Filename.concat mutable_disk_dir "mutable-disk.img" in
      let resolver = Filename.concat dir "resolver.sh" in
      let cloud_hypervisor = Filename.concat dir "cloud-hypervisor.sh" in
      let launch_log = Filename.concat dir "launch.log" in
      write_file kernel "kernel";
      write_file disk "disk";
      write_file initrd "initrd";
      Unix.mkdir mutable_disk_dir 0o755;
      write_file mutable_disk "mutable-disk";
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
          if [ \"$EPI_TARGET\" = \".#mutable-disk\" ]; then\n\
         \  echo \"kernel=" ^ kernel ^ "\"\n  echo \"disk=" ^ mutable_disk
       ^ "\"\n  echo \"initrd=" ^ initrd
       ^ "\"\n\
         \  echo \"cpus=2\"\n\
         \  echo \"memory_mib=1024\"\n\
         \  exit 0\n\
          fi\n\
          if [ \"$EPI_TARGET\" = \".#custom-cmdline\" ]; then\n\
         \  echo \"kernel=" ^ kernel ^ "\"\n  echo \"disk=" ^ disk
       ^ "\"\n  echo \"initrd=" ^ initrd
       ^ "\"\n\
         \  echo \"cmdline=console=ttyS0 root=/dev/vda1 ro\"\n\
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
      let genisoimage = Filename.concat dir "genisoimage.sh" in
      write_file genisoimage
        ("#!/usr/bin/env sh\n\
          # Mock genisoimage: create a fake ISO file at -output path\n\
          OUTPUT=\"\"\n\
          while [ $# -gt 0 ]; do\n\
         \  case \"$1\" in\n\
         \    -output) OUTPUT=\"$2\"; shift 2 ;;\n\
         \    *) shift ;;\n\
         \  esac\n\
          done\n\
          if [ -n \"$OUTPUT\" ]; then\n\
         \  echo \"mock-iso-content\" > \"$OUTPUT\"\n\
          fi\n\
          exit 0\n");
      let pasta = Filename.concat dir "pasta.sh" in
      write_file pasta
        "#!/usr/bin/env sh\n\
         # Mock pasta: find --socket arg, touch the socket file, stay alive\n\
         prev=\"\"\n\
         for arg in \"$@\"; do\n\
        \  if [ \"$prev\" = \"--socket\" ]; then\n\
        \    touch \"$arg\"\n\
        \  fi\n\
        \  prev=\"$arg\"\n\
         done\n\
         exec sleep 30\n";
      make_executable resolver;
      make_executable cloud_hypervisor;
      make_executable genisoimage;
      make_executable pasta;
      let extra_env =
        [
          ("EPI_TARGET_RESOLVER_CMD", resolver);
          ("EPI_CLOUD_HYPERVISOR_BIN", cloud_hypervisor);
          ("EPI_GENISOIMAGE_BIN", genisoimage);
          ("EPI_PASTA_BIN", pasta);
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
                "up: evaluating target=.#dev-a";
              assert_contains ~context:"explicit up output" stdout_explicit
                "up: building target artifacts";
              assert_contains ~context:"explicit up output" stdout_explicit
                "up: starting VM instance=dev-a";
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
  run_test ~name:"up emits stage progress messages during provisioning"
    (fun () ->
      with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
          with_state_file (fun state_file ->
              let result =
                run_cli_with_env ~bin ~state_file ~extra_env
                  [ "up"; "stage-test"; "--target"; ".#stage-test" ]
              in
              assert_success ~context:"stage progress up" result;
              let _, stdout, _ = result in
              assert_contains ~context:"stage: target evaluation start" stdout
                "up: evaluating target=.#stage-test";
              assert_contains ~context:"stage: launch preparation start" stdout
                "up: building target artifacts";
              assert_contains ~context:"stage: VM launch start" stdout
                "up: starting VM instance=stage-test";
              assert_contains ~context:"stage: provisioned message" stdout
                "up: provisioned instance=stage-test")));
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
  run_test ~name:"up rejects mixed mutable disk and target-built boot artifacts"
    (fun () ->
      with_mock_runtime (fun ~extra_env ~launch_log ~disk:_ ->
          with_state_file (fun state_file ->
              let failed =
                run_cli_with_env ~bin ~state_file ~extra_env
                  [ "up"; "dev-a"; "--target"; ".#mutable-disk" ]
              in
              assert_failure ~context:"mutable disk coherence failure" failed;
              let _, _, err = failed in
              assert_contains ~context:"coherence validation stage" err
                "descriptor validation failed";
              assert_contains ~context:"coherence validation message" err
                "launch inputs are not coherent";
              assert_contains ~context:"coherence guidance" err
                "fix target outputs";
              let launch_contents =
                if Sys.file_exists launch_log then
                  let channel = open_in launch_log in
                  Fun.protect
                    ~finally:(fun () -> close_in channel)
                    (fun () -> read_all channel)
                else ""
              in
              if String.length launch_contents > 0 then
                fail
                  "cloud-hypervisor was invoked despite coherence validation \n\
                   failure")));
  run_test ~name:"up uses target-provided cmdline when available" (fun () ->
      with_mock_runtime (fun ~extra_env ~launch_log ~disk:_ ->
          with_state_file (fun state_file ->
              let launched =
                run_cli_with_env ~bin ~state_file ~extra_env
                  [ "up"; "dev-cmdline"; "--target"; ".#custom-cmdline" ]
              in
              assert_success ~context:"custom cmdline up" launched;
              let launch_contents =
                if Sys.file_exists launch_log then
                  let channel = open_in launch_log in
                  Fun.protect
                    ~finally:(fun () -> close_in channel)
                    (fun () -> read_all channel)
                else ""
              in
              assert_contains ~context:"custom cmdline launch args"
                launch_contents "root=/dev/vda1")));
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
  run_test ~name:"console attaches to running instance serial socket" (fun () ->
      with_state_file (fun state_file ->
          with_temp_dir "epi-console-running" (fun dir ->
              with_sleep_process (fun pid ->
                  let serial_socket = Filename.concat dir "dev-a.sock" in
                  with_unix_socket_server ~socket_path:serial_socket
                    ~payload:"console-connected\n" (fun () ->
                      write_state_entry state_file
                        {
                          instance_name = "dev-a";
                          target = ".#dev-a";
                          pid = Some pid;
                          serial_socket = Some serial_socket;
                          disk = Some "/tmp/dev-a.disk";
                        };
                      let result =
                        run_cli ~bin ~state_file [ "console"; "dev-a" ]
                      in
                      assert_success ~context:"console running" result;
                      let _, out, _ = result in
                      assert_contains ~context:"console running stdout" out
                        "console-connected")))));
  run_test ~name:"console writes serial output to capture file" (fun () ->
      with_state_file (fun state_file ->
          with_temp_dir "epi-console-capture" (fun dir ->
              with_sleep_process (fun pid ->
                  let serial_socket = Filename.concat dir "dev-a.sock" in
                  let capture_path = Filename.concat dir "capture.log" in
                  with_unix_socket_server ~socket_path:serial_socket
                    ~payload:"capture-connected\n" (fun () ->
                      write_state_entry state_file
                        {
                          instance_name = "dev-a";
                          target = ".#dev-a";
                          pid = Some pid;
                          serial_socket = Some serial_socket;
                          disk = Some "/tmp/dev-a.disk";
                        };
                      let result =
                        run_cli_with_env ~bin ~state_file
                          ~extra_env:
                            [
                              ("EPI_CONSOLE_NON_INTERACTIVE", "1");
                              ("EPI_CONSOLE_CAPTURE_FILE", capture_path);
                            ]
                          [ "console"; "dev-a" ]
                      in
                      assert_success ~context:"console capture" result;
                      if not (Sys.file_exists capture_path) then
                        fail "console capture file was not created";
                      let captured =
                        let channel = open_in capture_path in
                        Fun.protect
                          ~finally:(fun () -> close_in channel)
                          (fun () -> read_all channel)
                      in
                      assert_contains ~context:"console capture contents"
                        captured "capture-connected")))));
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
  run_test ~name:"console non-interactive timeout reports guidance" (fun () ->
      with_state_file (fun state_file ->
          with_temp_dir "epi-console-timeout" (fun dir ->
              with_sleep_process (fun pid ->
                  let serial_socket = Filename.concat dir "dev-a.sock" in
                  with_hanging_unix_socket_server ~socket_path:serial_socket
                    ~hold_seconds:0.5 (fun () ->
                      write_state_entry state_file
                        {
                          instance_name = "dev-a";
                          target = ".#dev-a";
                          pid = Some pid;
                          serial_socket = Some serial_socket;
                          disk = Some "/tmp/dev-a.disk";
                        };
                      let result =
                        run_cli_with_env ~bin ~state_file
                          ~extra_env:
                            [
                              ("EPI_CONSOLE_NON_INTERACTIVE", "1");
                              ("EPI_CONSOLE_TIMEOUT_SECONDS", "0.05");
                            ]
                          [ "console"; "dev-a" ]
                      in
                      assert_failure ~context:"console timeout" result;
                      let _, _, err = result in
                      assert_contains ~context:"console timeout message" err
                        "Console session timed out for 'dev-a'";
                      assert_contains ~context:"console timeout guidance" err
                        "EPI_CONSOLE_TIMEOUT_SECONDS")))));
  run_test ~name:"up --console provisions and attaches to serial socket"
    (fun () ->
      with_mock_runtime (fun ~extra_env ~launch_log ~disk:_ ->
          with_state_file (fun state_file ->
              let wait_for_launch () =
                let rec loop remaining =
                  if remaining <= 0 then
                    fail "mock launch log did not appear in time"
                  else if Sys.file_exists launch_log then
                    let channel = open_in launch_log in
                    let contents =
                      Fun.protect
                        ~finally:(fun () -> close_in channel)
                        (fun () -> read_all channel)
                    in
                    if String.trim contents <> "" then ()
                    else
                      let _ = Unix.select [] [] [] 0.01 in
                      loop (remaining - 1)
                  else
                    let _ = Unix.select [] [] [] 0.01 in
                    loop (remaining - 1)
                in
                loop 400
              in
              let serial_socket =
                Filename.concat
                  (Filename.concat (Filename.dirname state_file) "runtime")
                  "dev-a.serial.sock"
              in
              with_delayed_unix_socket_server ~socket_path:serial_socket
                ~payload:"up-console\n" ~before_bind:wait_for_launch (fun () ->
                  let result =
                    run_cli_with_env ~bin ~state_file ~extra_env
                      [ "up"; "dev-a"; "--target"; ".#dev-a"; "--console" ]
                  in
                  assert_success ~context:"up console fresh" result;
                  let _, out, _ = result in
                  assert_contains ~context:"up console fresh stdout" out
                    "up-console";
                  let launch_contents =
                    if Sys.file_exists launch_log then
                      let channel = open_in launch_log in
                      Fun.protect
                        ~finally:(fun () -> close_in channel)
                        (fun () -> read_all channel)
                    else ""
                  in
                  assert_contains ~context:"up console launch invoked"
                    launch_contents "--serial"))));
  run_test ~name:"up --console attaches to already running instance" (fun () ->
      with_mock_runtime (fun ~extra_env ~launch_log ~disk:_ ->
          with_state_file (fun state_file ->
              with_temp_dir "epi-up-console-running" (fun dir ->
                  with_sleep_process (fun pid ->
                      let serial_socket = Filename.concat dir "dev-a.sock" in
                      with_unix_socket_server ~socket_path:serial_socket
                        ~payload:"up-console-running\n" (fun () ->
                          write_state_entry state_file
                            {
                              instance_name = "dev-a";
                              target = ".#dev-a";
                              pid = Some pid;
                              serial_socket = Some serial_socket;
                              disk = Some "/tmp/dev-a.disk";
                            };
                          let result =
                            run_cli_with_env ~bin ~state_file ~extra_env
                              [
                                "up";
                                "dev-a";
                                "--target";
                                ".#dev-a";
                                "--console";
                              ]
                          in
                          assert_success ~context:"up console running" result;
                          let _, out, _ = result in
                          assert_contains ~context:"up console running stdout"
                            out "up-console-running";
                          let launch_contents =
                            if Sys.file_exists launch_log then
                              let channel = open_in launch_log in
                              Fun.protect
                                ~finally:(fun () -> close_in channel)
                                (fun () -> read_all channel)
                            else ""
                          in
                          if String.trim launch_contents <> "" then
                            fail
                              "expected up --console to skip VM provisioning \
                               for running instance"))))));
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
  run_test
    ~name:
      "seed ISO generation creates valid user-data and meta-data with correct \
       content"
    (fun () ->
      with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
          with_state_file (fun state_file ->
              let result =
                run_cli_with_env ~bin ~state_file ~extra_env
                  [ "up"; "seed-test"; "--target"; ".#dev" ]
              in
              assert_success ~context:"seed iso up" result;
              let runtime_dir =
                Filename.concat (Filename.dirname state_file) "runtime"
              in
              let staging_dir =
                Filename.concat runtime_dir "seed-test.cidata"
              in
              let user_data_path =
                Filename.concat staging_dir "user-data"
              in
              let meta_data_path =
                Filename.concat staging_dir "meta-data"
              in
              if not (Sys.file_exists user_data_path) then
                fail "user-data file was not created";
              if not (Sys.file_exists meta_data_path) then
                fail "meta-data file was not created";
              let user_data =
                let channel = open_in user_data_path in
                Fun.protect
                  ~finally:(fun () -> close_in channel)
                  (fun () -> read_all channel)
              in
              let meta_data =
                let channel = open_in meta_data_path in
                Fun.protect
                  ~finally:(fun () -> close_in channel)
                  (fun () -> read_all channel)
              in
              assert_contains ~context:"user-data cloud-config header"
                user_data "#cloud-config";
              assert_contains ~context:"user-data users section" user_data
                "users:";
              assert_contains ~context:"user-data wheel group" user_data
                "groups: wheel";
              assert_contains ~context:"user-data sudo" user_data
                "sudo: ALL=(ALL) NOPASSWD:ALL";
              assert_contains ~context:"user-data shell" user_data
                "shell: /bin/bash";
              assert_contains ~context:"meta-data instance-id" meta_data
                "instance-id: seed-test";
              assert_contains ~context:"meta-data local-hostname" meta_data
                "local-hostname: seed-test")));
  run_test
    ~name:"SSH keys are read from ~/.ssh/*.pub and included in user-data"
    (fun () ->
      with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
          with_state_file (fun state_file ->
              with_temp_dir "epi-ssh-key-test" (fun ssh_dir ->
                  write_file
                    (Filename.concat ssh_dir "id_ed25519.pub")
                    "ssh-ed25519 AAAAC3test testkey@host";
                  write_file
                    (Filename.concat ssh_dir "id_rsa.pub")
                    "ssh-rsa AAAAB3test testkey2@host";
                  let extra_env =
                    ("EPI_SSH_DIR", ssh_dir) :: extra_env
                  in
                  let result =
                    run_cli_with_env ~bin ~state_file ~extra_env
                      [ "up"; "ssh-key-test"; "--target"; ".#dev" ]
                  in
                  assert_success ~context:"ssh key up" result;
                  let runtime_dir =
                    Filename.concat (Filename.dirname state_file) "runtime"
                  in
                  let user_data_path =
                    Filename.concat
                      (Filename.concat runtime_dir "ssh-key-test.cidata")
                      "user-data"
                  in
                  if not (Sys.file_exists user_data_path) then
                    fail "user-data file was not created";
                  let user_data =
                    let channel = open_in user_data_path in
                    Fun.protect
                      ~finally:(fun () -> close_in channel)
                      (fun () -> read_all channel)
                  in
                  assert_contains ~context:"user-data ssh_authorized_keys"
                    user_data "ssh_authorized_keys:";
                  assert_contains ~context:"user-data ed25519 key" user_data
                    "ssh-ed25519 AAAAC3test testkey@host";
                  assert_contains ~context:"user-data rsa key" user_data
                    "ssh-rsa AAAAB3test testkey2@host"))));
  run_test
    ~name:"missing SSH keys produce a warning but don't fail provisioning"
    (fun () ->
      with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
          with_state_file (fun state_file ->
              with_temp_dir "epi-no-ssh-test" (fun empty_ssh_dir ->
                  let extra_env =
                    ("EPI_SSH_DIR", empty_ssh_dir) :: extra_env
                  in
                  let result =
                    run_cli_with_env ~bin ~state_file ~extra_env
                      [ "up"; "no-ssh-test"; "--target"; ".#dev" ]
                  in
                  assert_success ~context:"no ssh keys up" result;
                  let _, _, stderr = result in
                  assert_contains ~context:"no ssh keys warning" stderr
                    "no SSH public keys found";
                  let runtime_dir =
                    Filename.concat (Filename.dirname state_file) "runtime"
                  in
                  let user_data_path =
                    Filename.concat
                      (Filename.concat runtime_dir "no-ssh-test.cidata")
                      "user-data"
                  in
                  if not (Sys.file_exists user_data_path) then
                    fail "user-data file was not created";
                  let user_data =
                    let channel = open_in user_data_path in
                    Fun.protect
                      ~finally:(fun () -> close_in channel)
                      (fun () -> read_all channel)
                  in
                  if contains user_data "ssh_authorized_keys" then
                    fail
                      "ssh_authorized_keys should be omitted when no keys \
                       found"))));
  run_test ~name:"missing genisoimage produces a clear error" (fun () ->
      with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
          with_state_file (fun state_file ->
              let extra_env =
                List.filter
                  (fun (key, _) ->
                    not (String.equal key "EPI_GENISOIMAGE_BIN"))
                  extra_env
                @ [ ("EPI_GENISOIMAGE_BIN", "nonexistent-genisoimage-bin") ]
              in
              let result =
                run_cli_with_env ~bin ~state_file ~extra_env
                  [ "up"; "no-genisoimage"; "--target"; ".#dev" ]
              in
              assert_failure ~context:"missing genisoimage" result;
              let _, _, err = result in
              assert_contains ~context:"genisoimage error message" err
                "genisoimage not found";
              assert_contains ~context:"genisoimage cdrkit hint" err
                "cdrkit")));
  run_test
    ~name:"seed ISO is passed as additional --disk argument to cloud-hypervisor"
    (fun () ->
      with_mock_runtime (fun ~extra_env ~launch_log ~disk:_ ->
          with_state_file (fun state_file ->
              let result =
                run_cli_with_env ~bin ~state_file ~extra_env
                  [ "up"; "disk-test"; "--target"; ".#dev" ]
              in
              assert_success ~context:"seed iso disk arg up" result;
              let launch_contents =
                if Sys.file_exists launch_log then
                  let channel = open_in launch_log in
                  Fun.protect
                    ~finally:(fun () -> close_in channel)
                    (fun () -> read_all channel)
                else ""
              in
              assert_contains ~context:"seed iso disk arg" launch_contents
                "cidata.iso,readonly=on";
              assert_contains ~context:"pasta net arg" launch_contents
                "--net vhost_user=true,socket=")));
  run_test ~name:"EPI_PASTA_BIN overrides pasta binary path" (fun () ->
      with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
          with_temp_dir "epi-pasta-override" (fun custom_dir ->
              with_state_file (fun state_file ->
                  let custom_pasta =
                    Filename.concat custom_dir "custom-pasta.sh"
                  in
                  write_file custom_pasta
                    "#!/usr/bin/env sh\n\
                     prev=\"\"\n\
                     for arg in \"$@\"; do\n\
                    \  if [ \"$prev\" = \"--socket\" ]; then\n\
                    \    touch \"$arg\"\n\
                    \  fi\n\
                    \  prev=\"$arg\"\n\
                     done\n\
                     exec sleep 30\n";
                  make_executable custom_pasta;
                  let extra_env =
                    List.filter
                      (fun (key, _) ->
                        not (String.equal key "EPI_PASTA_BIN"))
                      extra_env
                    @ [ ("EPI_PASTA_BIN", custom_pasta) ]
                  in
                  let result =
                    run_cli_with_env ~bin ~state_file ~extra_env
                      [ "up"; "pasta-override"; "--target"; ".#dev" ]
                  in
                  assert_success ~context:"custom pasta bin up" result))));
  run_test ~name:"missing pasta binary produces a clear error" (fun () ->
      with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
          with_state_file (fun state_file ->
              let extra_env =
                List.filter
                  (fun (key, _) -> not (String.equal key "EPI_PASTA_BIN"))
                  extra_env
                @ [ ("EPI_PASTA_BIN", "nonexistent-pasta-bin") ]
              in
              let result =
                run_cli_with_env ~bin ~state_file ~extra_env
                  [ "up"; "no-pasta"; "--target"; ".#dev" ]
              in
              assert_failure ~context:"missing pasta" result;
              let _, _, err = result in
              assert_contains ~context:"pasta error message" err "pasta";
              assert_contains ~context:"pasta EPI_PASTA_BIN hint" err
                "EPI_PASTA_BIN")));
  ()
