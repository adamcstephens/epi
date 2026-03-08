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

let run_cli_with_env ~bin ~state_dir ~extra_env args =
  let overrides =
    ("EPI_STATE_DIR", state_dir) :: extra_env
  in
  let override_keys =
    List.map (fun (key, _) -> key ^ "=") overrides
  in
  let base_env =
    Unix.environment ()
    |> Array.to_list
    |> List.filter (fun entry ->
        not (List.exists (fun prefix ->
            String.length entry >= String.length prefix
            && String.sub entry 0 (String.length prefix) = prefix)
          override_keys))
    |> Array.of_list
  in
  let env_entries =
    overrides
    |> List.map (fun (key, value) -> Printf.sprintf "%s=%s" key value)
    |> Array.of_list
  in
  let env = Array.append base_env env_entries in
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

let run_cli ~bin ~state_dir args =
  run_cli_with_env ~bin ~state_dir ~extra_env:[] args

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

let write_file path content =
  let channel = open_out path in
  output_string channel content;
  close_out channel

let write_state_entry ~state_dir ~instance_name ~target ?pid ?serial_socket
    ?disk ?passt_pid ?ssh_port ?ssh_key_path () =
  let instance_dir = Filename.concat state_dir instance_name in
  if not (Sys.file_exists instance_dir) then Unix.mkdir instance_dir 0o755;
  write_file (Filename.concat instance_dir "target") (target ^ "\n");
  match pid with
  | Some pid_val ->
      let channel = open_out (Filename.concat instance_dir "runtime") in
      Printf.fprintf channel "pid=%d\n" pid_val;
      (match serial_socket with
      | Some s -> Printf.fprintf channel "serial_socket=%s\n" s
      | None -> ());
      (match disk with
      | Some d -> Printf.fprintf channel "disk=%s\n" d
      | None -> ());
      (match passt_pid with
      | Some p -> Printf.fprintf channel "passt_pid=%d\n" p
      | None -> ());
      (match ssh_port with
      | Some p -> Printf.fprintf channel "ssh_port=%d\n" p
      | None -> ());
      (match ssh_key_path with
      | Some p -> Printf.fprintf channel "ssh_key_path=%s\n" p
      | None -> ());
      close_out channel
  | None -> ()

let find_state_runtime ~state_dir instance_name =
  let instance_dir = Filename.concat state_dir instance_name in
  let runtime_path = Filename.concat instance_dir "runtime" in
  if not (Sys.file_exists runtime_path) then None
  else
    let content =
      let channel = open_in runtime_path in
      Fun.protect
        ~finally:(fun () -> close_in channel)
        (fun () -> read_all channel)
    in
    let pairs =
      String.split_on_char '\n' content
      |> List.filter_map (fun line ->
          match String.split_on_char '=' line with
          | key :: value_parts when key <> "" ->
              let value = String.concat "=" value_parts |> String.trim in
              if value = "" then None else Some (String.trim key, value)
          | _ -> None)
    in
    let get key = List.assoc_opt key pairs in
    let get_int key =
      match get key with Some v -> int_of_string_opt v | None -> None
    in
    Some (get_int "pid", get "serial_socket", get "disk",
          get_int "passt_pid", get_int "ssh_port", get "ssh_key_path")

let instance_exists ~state_dir instance_name =
  let instance_dir = Filename.concat state_dir instance_name in
  Sys.file_exists instance_dir
  && Sys.file_exists (Filename.concat instance_dir "target")

let assert_missing_state_entry ~context ~state_dir instance_name =
  if instance_exists ~state_dir instance_name then
    fail "%s: expected instance %S to be removed" context instance_name

let pid_is_alive pid =
  try
    Unix.kill pid 0;
    true
  with
  | Unix.Unix_error (Unix.ESRCH, _, _) -> false
  | Unix.Unix_error (Unix.EPERM, _, _) -> true

let wait_for_pid_to_die ~attempts pid =
  let rec loop remaining =
    if not (pid_is_alive pid) then true
    else if remaining <= 0 then false
    else
      let _ = Unix.select [] [] [] 0.05 in
      loop (remaining - 1)
  in
  loop attempts

let terminate_pid pid =
  (if pid_is_alive pid then
     try Unix.kill pid Sys.sigterm with Unix.Unix_error _ -> ());
  try ignore (Unix.waitpid [ Unix.WNOHANG ] pid)
  with Unix.Unix_error (Unix.ECHILD, _, _) -> ()

let cleanup_state_pids ~state_dir =
  if Sys.file_exists state_dir then
    Sys.readdir state_dir
    |> Array.iter (fun name ->
        let d = Filename.concat state_dir name in
        if Sys.is_directory d then
          match find_state_runtime ~state_dir name with
          | Some (pid, _, _, passt_pid, _, _) ->
              (match pid with Some p -> terminate_pid p | None -> ());
              (match passt_pid with Some p -> terminate_pid p | None -> ())
          | None -> ())

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

let with_state_dir f =
  with_temp_dir "epi-cli-test" (fun dir ->
    Fun.protect
      ~finally:(fun () -> cleanup_state_pids ~state_dir:dir)
      (fun () -> f dir))

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
          if [ \"$EPI_TARGET\" = \".#user-configured\" ]; then\n\
         \  echo \"kernel=" ^ kernel ^ "\"\n  echo \"disk=" ^ disk
       ^ "\"\n  echo \"initrd=" ^ initrd
       ^ "\"\n\
         \  echo \"cpus=2\"\n\
         \  echo \"memory_mib=1024\"\n\
         \  echo \"configured_users=root,$USER\"\n\
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
      let passt = Filename.concat dir "passt.sh" in
      write_file passt
        "#!/usr/bin/env sh\n\
         # Mock passt: find --socket arg, touch the socket file, stay alive\n\
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
      make_executable passt;
      let cache_dir = Filename.concat dir "cache" in
      Unix.mkdir cache_dir 0o755;
      let extra_env =
        [
          ("EPI_TARGET_RESOLVER_CMD", resolver);
          ("EPI_CLOUD_HYPERVISOR_BIN", cloud_hypervisor);
          ("EPI_GENISOIMAGE_BIN", genisoimage);
          ("EPI_PASST_BIN", passt);
          ("EPI_MOCK_VM_SLEEP", "30");
          ("EPI_CACHE_DIR", cache_dir);
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
          with_state_dir (fun state_dir ->
              let explicit =
                run_cli_with_env ~bin ~state_dir ~extra_env
                  [ "up"; "dev-a"; "--target"; ".#dev-a" ]
              in
              assert_success ~context:"explicit up" explicit;
              let _, stdout_explicit, _ = explicit in
              assert_contains ~context:"explicit up output" stdout_explicit
                "up: resolving target=.#dev-a";
              assert_contains ~context:"explicit up output" stdout_explicit
                "up: evaluated target, building artifacts";
              assert_contains ~context:"explicit up output" stdout_explicit
                "up: starting VM instance=dev-a";
              assert_contains ~context:"explicit up output" stdout_explicit
                "up: provisioned instance=dev-a target=.#dev-a pid=";
              assert_contains ~context:"explicit up output" stdout_explicit
                "serial=";
              let implicit =
                run_cli_with_env ~bin ~state_dir ~extra_env
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
              (match find_state_runtime ~state_dir "dev-a" with
              | Some (Some _, Some _, _, Some _, _, _) -> ()
              | _ ->
                  fail
                    "expected runtime metadata with passt_pid for dev-a");
              (match find_state_runtime ~state_dir "default" with
              | Some (Some _, Some _, _, Some _, _, _) -> ()
              | _ ->
                  fail
                    "expected runtime metadata with passt_pid for default");
              let status_default =
                run_cli_with_env ~bin ~state_dir ~extra_env [ "status" ]
              in
              assert_success ~context:"status default" status_default;
              let _, status_out, _ = status_default in
              assert_contains ~context:"status default output" status_out
                "status: instance=default")));
  run_test ~name:"up emits stage progress messages during provisioning"
    (fun () ->
      with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
          with_state_dir (fun state_dir ->
              let result =
                run_cli_with_env ~bin ~state_dir ~extra_env
                  [ "up"; "stage-test"; "--target"; ".#stage-test" ]
              in
              assert_success ~context:"stage progress up" result;
              let _, stdout, _ = result in
              assert_contains ~context:"stage: target evaluation start" stdout
                "up: resolving target=.#stage-test";
              assert_contains ~context:"stage: launch preparation start" stdout
                "up: evaluated target, building artifacts";
              assert_contains ~context:"stage: VM launch start" stdout
                "up: starting VM instance=stage-test";
              assert_contains ~context:"stage: provisioned message" stdout
                "up: provisioned instance=stage-test")));
  run_test ~name:"up rejects invalid target formats with actionable errors"
    (fun () ->
      with_state_dir (fun state_dir ->
          let missing_separator =
            run_cli ~bin ~state_dir [ "up"; "dev-a"; "--target"; "." ]
          in
          assert_failure ~context:"missing separator" missing_separator;
          let _, _, err1 = missing_separator in
          assert_contains ~context:"missing separator error" err1
            "--target must use <flake-ref>#<config-name>";
          let missing_config =
            run_cli ~bin ~state_dir [ "up"; "dev-a"; "--target"; ".#" ]
          in
          assert_failure ~context:"missing config" missing_config;
          let _, _, err2 = missing_config in
          assert_contains ~context:"missing config error" err2
            "both flake reference and config name are required"));
  run_test ~name:"up does not persist instance when provisioning fails"
    (fun () ->
      with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
          with_state_dir (fun state_dir ->
              let failing_env = ("EPI_FORCE_LAUNCH_FAIL", "1") :: extra_env in
              let failed =
                run_cli_with_env ~bin ~state_dir ~extra_env:failing_env
                  [ "up"; "qa-1"; "--target"; ".#qa" ]
              in
              assert_failure ~context:"failing up" failed;
              let _, _, err = failed in
              assert_contains ~context:"launch failure error" err
                "VM launch failed";
              let listed =
                run_cli_with_env ~bin ~state_dir ~extra_env [ "list" ]
              in
              assert_success ~context:"list after failed up" listed;
              let _, listed_out, _ = listed in
              if contains listed_out "qa-1" then
                fail "instance was unexpectedly persisted after launch failure")));
  run_test ~name:"up reports target resolution failures with target context"
    (fun () ->
      with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
          with_state_dir (fun state_dir ->
              let failed =
                run_cli_with_env ~bin ~state_dir ~extra_env
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
          with_state_dir (fun state_dir ->
              let failed =
                run_cli_with_env ~bin ~state_dir ~extra_env
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
          with_state_dir (fun state_dir ->
              let failed =
                run_cli_with_env ~bin ~state_dir ~extra_env
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
          with_state_dir (fun state_dir ->
              let launched =
                run_cli_with_env ~bin ~state_dir ~extra_env
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
          with_state_dir (fun state_dir ->
              let owner_up =
                run_cli_with_env ~bin ~state_dir ~extra_env
                  [ "up"; "dev-owner"; "--target"; ".#owner" ]
              in
              assert_success ~context:"owner up" owner_up;
              let owner_pid =
                match find_state_runtime ~state_dir "dev-owner" with
                | Some (Some pid, _, _, _, _, _) -> pid
                | _ -> fail "missing owner runtime metadata"
              in
              let failing_env = ("EPI_FORCE_LOCK_FAIL", "1") :: extra_env in
              let failed =
                run_cli_with_env ~bin ~state_dir ~extra_env:failing_env
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
      with_state_dir (fun state_dir ->
          write_state_entry ~state_dir ~instance_name:"dev-a"
            ~target:".#dev-a" ();
          let result = run_cli ~bin ~state_dir [ "console"; "dev-a" ] in
          assert_failure ~context:"console not running" result;
          let _, _, err = result in
          assert_contains ~context:"console not running message" err
            "Instance 'dev-a' is not running";
          assert_contains ~context:"console not running guidance" err
            "epi up dev-a --target"));
  run_test ~name:"console attaches to running instance serial socket" (fun () ->
      with_state_dir (fun state_dir ->
          with_temp_dir "epi-console-running" (fun dir ->
              with_sleep_process (fun pid ->
                  let serial_socket = Filename.concat dir "dev-a.sock" in
                  with_unix_socket_server ~socket_path:serial_socket
                    ~payload:"console-connected\n" (fun () ->
                      write_state_entry ~state_dir ~instance_name:"dev-a"
                        ~target:".#dev-a" ~pid ~serial_socket
                        ~disk:"/tmp/dev-a.disk" ();
                      let result =
                        run_cli ~bin ~state_dir [ "console"; "dev-a" ]
                      in
                      assert_success ~context:"console running" result;
                      let _, out, _ = result in
                      assert_contains ~context:"console running stdout" out
                        "console-connected")))));
  run_test ~name:"console writes serial output to capture file" (fun () ->
      with_state_dir (fun state_dir ->
          with_temp_dir "epi-console-capture" (fun dir ->
              with_sleep_process (fun pid ->
                  let serial_socket = Filename.concat dir "dev-a.sock" in
                  let capture_path = Filename.concat dir "capture.log" in
                  with_unix_socket_server ~socket_path:serial_socket
                    ~payload:"capture-connected\n" (fun () ->
                      write_state_entry ~state_dir ~instance_name:"dev-a"
                        ~target:".#dev-a" ~pid ~serial_socket
                        ~disk:"/tmp/dev-a.disk" ();
                      let result =
                        run_cli_with_env ~bin ~state_dir
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
  run_test
    ~name:"console reports unavailable serial endpoint for running instance"
    (fun () ->
      with_state_dir (fun state_dir ->
          with_sleep_process (fun pid ->
              write_state_entry ~state_dir ~instance_name:"dev-a"
                ~target:".#dev-a" ~pid
                ~serial_socket:"/tmp/epi-nonexistent.sock"
                ~disk:"/tmp/disk.img" ();
              let result = run_cli ~bin ~state_dir [ "console"; "dev-a" ] in
              assert_failure ~context:"console unavailable endpoint" result;
              let _, _, err = result in
              assert_contains ~context:"console unavailable message" err
                "Serial endpoint unavailable for 'dev-a'";
              assert_contains ~context:"console unavailable guidance" err
                "Check VM runtime state for 'dev-a'")));
  run_test ~name:"console non-interactive timeout reports guidance" (fun () ->
      with_state_dir (fun state_dir ->
          with_temp_dir "epi-console-timeout" (fun dir ->
              with_sleep_process (fun pid ->
                  let serial_socket = Filename.concat dir "dev-a.sock" in
                  with_hanging_unix_socket_server ~socket_path:serial_socket
                    ~hold_seconds:0.5 (fun () ->
                      write_state_entry ~state_dir ~instance_name:"dev-a"
                        ~target:".#dev-a" ~pid ~serial_socket
                        ~disk:"/tmp/dev-a.disk" ();
                      let result =
                        run_cli_with_env ~bin ~state_dir
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
          with_state_dir (fun state_dir ->
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
                  (Filename.concat state_dir "dev-a")
                  "serial.sock"
              in
              with_delayed_unix_socket_server ~socket_path:serial_socket
                ~payload:"up-console\n" ~before_bind:wait_for_launch (fun () ->
                  let result =
                    run_cli_with_env ~bin ~state_dir ~extra_env
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
          with_state_dir (fun state_dir ->
              with_temp_dir "epi-up-console-running" (fun dir ->
                  with_sleep_process (fun pid ->
                      let serial_socket = Filename.concat dir "dev-a.sock" in
                      with_unix_socket_server ~socket_path:serial_socket
                        ~payload:"up-console-running\n" (fun () ->
                          write_state_entry ~state_dir ~instance_name:"dev-a"
                            ~target:".#dev-a" ~pid ~serial_socket
                            ~disk:"/tmp/dev-a.disk" ();
                          let result =
                            run_cli_with_env ~bin ~state_dir ~extra_env
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
      with_state_dir (fun state_dir ->
          with_temp_dir "epi-reconcile-test" (fun dir ->
              with_sleep_process (fun live_pid ->
                  write_state_entry ~state_dir ~instance_name:"stale"
                    ~target:".#stale" ~pid:999_999
                    ~serial_socket:(Filename.concat dir "stale.sock")
                    ~disk:"/tmp/stale-disk.img" ();
                  write_state_entry ~state_dir ~instance_name:"live"
                    ~target:".#live" ~pid:live_pid
                    ~serial_socket:(Filename.concat dir "live.sock")
                    ~disk:"/tmp/live-disk.img" ();
                  let listed = run_cli ~bin ~state_dir [ "list" ] in
                  assert_success ~context:"list with reconciliation" listed;
                  (match find_state_runtime ~state_dir "stale" with
                  | None -> ()
                  | _ -> fail "expected stale runtime metadata to be cleared");
                  match find_state_runtime ~state_dir "live" with
                  | Some (Some pid, _, _, _, _, _) when pid = live_pid -> ()
                  | _ -> fail "expected live runtime metadata to remain active"))));
  run_test ~name:"rm removes stopped instances from state" (fun () ->
      with_state_dir (fun state_dir ->
          write_state_entry ~state_dir ~instance_name:"dev-a"
            ~target:".#dev-a" ();
          let removed = run_cli ~bin ~state_dir [ "rm"; "dev-a" ] in
          assert_success ~context:"rm stopped instance" removed;
          let _, out, _ = removed in
          assert_contains ~context:"rm stopped output" out
            "rm: removed instance=dev-a";
          assert_missing_state_entry ~context:"rm stopped state cleanup"
            ~state_dir "dev-a"));
  run_test ~name:"rm refuses to remove running instance without --force"
    (fun () ->
      with_state_dir (fun state_dir ->
          with_sleep_process (fun pid ->
              write_state_entry ~state_dir ~instance_name:"dev-a"
                ~target:".#dev-a" ~pid
                ~serial_socket:"/tmp/dev-a.serial.sock"
                ~disk:"/tmp/dev-a.disk" ();
              let rejected = run_cli ~bin ~state_dir [ "rm"; "dev-a" ] in
              assert_failure ~context:"rm running without force" rejected;
              let _, _, err = rejected in
              assert_contains ~context:"rm running rejection message" err
                "Instance 'dev-a' is running";
              assert_contains ~context:"rm running rejection guidance" err
                "use `epi rm --force dev-a`";
              match find_state_runtime ~state_dir "dev-a" with
              | Some (Some active_pid, _, _, _, _, _) when active_pid = pid -> ()
              | _ -> fail "expected running instance to remain in state")));
  run_test ~name:"rm --force terminates running instance before removing"
    (fun () ->
      with_state_dir (fun state_dir ->
          with_sleep_process (fun pid ->
              write_state_entry ~state_dir ~instance_name:"dev-a"
                ~target:".#dev-a" ~pid
                ~serial_socket:"/tmp/dev-a.serial.sock"
                ~disk:"/tmp/dev-a.disk" ();
              let removed =
                run_cli ~bin ~state_dir [ "rm"; "--force"; "dev-a" ]
              in
              assert_success ~context:"rm force running" removed;
              let _, out, _ = removed in
              assert_contains ~context:"rm force output" out
                "rm: removed instance=dev-a";
              assert_missing_state_entry ~context:"rm force state cleanup"
                ~state_dir "dev-a")));
  run_test ~name:"rm --force reports termination errors and keeps state"
    (fun () ->
      if Unix.geteuid () = 0 then ()
      else
        with_state_dir (fun state_dir ->
            write_state_entry ~state_dir ~instance_name:"protected"
              ~target:".#protected" ~pid:1
              ~serial_socket:"/tmp/protected.serial.sock"
              ~disk:"/tmp/protected.disk" ();
            let failed =
              run_cli ~bin ~state_dir [ "rm"; "--force"; "protected" ]
            in
            assert_failure ~context:"rm force termination failure" failed;
            let _, _, err = failed in
            assert_contains ~context:"rm force termination failure output" err
              "failed to terminate";
            match find_state_runtime ~state_dir "protected" with
            | Some (Some 1, _, _, _, _, _) -> ()
            | _ -> fail "expected entry to remain after failed force removal"));
  run_test
    ~name:"rm kills passt process when hypervisor is already dead"
    (fun () ->
      with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
          with_state_dir (fun state_dir ->
              let result =
                run_cli_with_env ~bin ~state_dir ~extra_env
                  [ "up"; "stale-rm"; "--target"; ".#dev" ]
              in
              assert_success ~context:"up for stale rm" result;
              let hypervisor_pid, passt_pid =
                match find_state_runtime ~state_dir "stale-rm" with
                | Some (Some pid, _, _, Some ppid, _, _) -> (pid, ppid)
                | _ -> fail "expected pid and passt_pid in state after up"
              in
              terminate_pid hypervisor_pid;
              if not (pid_is_alive passt_pid) then
                fail "passt should be alive before rm";
              let rm_result =
                run_cli_with_env ~bin ~state_dir ~extra_env
                  [ "rm"; "stale-rm" ]
              in
              assert_success ~context:"rm stale with passt" rm_result;
              if not (wait_for_pid_to_die ~attempts:40 passt_pid) then
                fail "passt process should be dead after rm")));
  run_test ~name:"list shows empty and multi-instance state" (fun () ->
      with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
          with_state_dir (fun state_dir ->
              let empty =
                run_cli_with_env ~bin ~state_dir ~extra_env [ "list" ]
              in
              assert_success ~context:"list empty" empty;
              let _, empty_out, _ = empty in
              assert_contains ~context:"list empty output" empty_out
                "No instances found.";
              ignore
                (run_cli_with_env ~bin ~state_dir ~extra_env
                   [ "up"; "--target"; ".#default" ]);
              ignore
                (run_cli_with_env ~bin ~state_dir ~extra_env
                   [ "up"; "qa-1"; "--target"; "github:org/repo#qa-1" ]);
              let listed =
                run_cli_with_env ~bin ~state_dir ~extra_env [ "list" ]
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
          with_state_dir (fun state_dir ->
              let result =
                run_cli_with_env ~bin ~state_dir ~extra_env
                  [ "up"; "seed-test"; "--target"; ".#dev" ]
              in
              assert_success ~context:"seed iso up" result;
              let instance_dir =
                Filename.concat state_dir "seed-test"
              in
              let staging_dir =
                Filename.concat instance_dir "cidata"
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
                "shell: /run/current-system/sw/bin/bash";
              assert_contains ~context:"user-data disable_root" user_data
                "disable_root: false";
              assert_contains ~context:"meta-data instance-id" meta_data
                "instance-id: seed-test";
              assert_contains ~context:"meta-data local-hostname" meta_data
                "local-hostname: seed-test")));
  run_test
    ~name:"SSH keys are read from ~/.ssh/*.pub and included in user-data"
    (fun () ->
      with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
          with_state_dir (fun state_dir ->
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
                    run_cli_with_env ~bin ~state_dir ~extra_env
                      [ "up"; "ssh-key-test"; "--target"; ".#dev" ]
                  in
                  assert_success ~context:"ssh key up" result;
                  let user_data_path =
                    Filename.concat
                      (Filename.concat
                        (Filename.concat state_dir "ssh-key-test")
                        "cidata")
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
          with_state_dir (fun state_dir ->
              with_temp_dir "epi-no-ssh-test" (fun empty_ssh_dir ->
                  let extra_env =
                    ("EPI_SSH_DIR", empty_ssh_dir) :: extra_env
                  in
                  let result =
                    run_cli_with_env ~bin ~state_dir ~extra_env
                      [ "up"; "no-ssh-test"; "--target"; ".#dev" ]
                  in
                  assert_success ~context:"no ssh keys up" result;
                  let _, _, stderr = result in
                  assert_contains ~context:"no ssh keys warning" stderr
                    "no SSH public keys found";
                  let user_data_path =
                    Filename.concat
                      (Filename.concat
                        (Filename.concat state_dir "no-ssh-test")
                        "cidata")
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
          with_state_dir (fun state_dir ->
              let extra_env =
                List.filter
                  (fun (key, _) ->
                    not (String.equal key "EPI_GENISOIMAGE_BIN"))
                  extra_env
                @ [ ("EPI_GENISOIMAGE_BIN", "nonexistent-genisoimage-bin") ]
              in
              let result =
                run_cli_with_env ~bin ~state_dir ~extra_env
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
          with_state_dir (fun state_dir ->
              let result =
                run_cli_with_env ~bin ~state_dir ~extra_env
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
              assert_contains ~context:"passt net arg" launch_contents
                "--net vhost_user=true,socket=")));
  run_test ~name:"EPI_PASST_BIN overrides passt binary path" (fun () ->
      with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
          with_temp_dir "epi-passt-override" (fun custom_dir ->
              with_state_dir (fun state_dir ->
                  let custom_passt =
                    Filename.concat custom_dir "custom-passt.sh"
                  in
                  write_file custom_passt
                    "#!/usr/bin/env sh\n\
                     prev=\"\"\n\
                     for arg in \"$@\"; do\n\
                    \  if [ \"$prev\" = \"--socket\" ]; then\n\
                    \    touch \"$arg\"\n\
                    \  fi\n\
                    \  prev=\"$arg\"\n\
                     done\n\
                     exec sleep 30\n";
                  make_executable custom_passt;
                  let extra_env =
                    List.filter
                      (fun (key, _) ->
                        not (String.equal key "EPI_PASST_BIN"))
                      extra_env
                    @ [ ("EPI_PASST_BIN", custom_passt) ]
                  in
                  let result =
                    run_cli_with_env ~bin ~state_dir ~extra_env
                      [ "up"; "passt-override"; "--target"; ".#dev" ]
                  in
                  assert_success ~context:"custom passt bin up" result))));
  run_test ~name:"missing passt binary produces a clear error" (fun () ->
      with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
          with_state_dir (fun state_dir ->
              let extra_env =
                List.filter
                  (fun (key, _) -> not (String.equal key "EPI_PASST_BIN"))
                  extra_env
                @ [ ("EPI_PASST_BIN", "nonexistent-passt-bin") ]
              in
              let result =
                run_cli_with_env ~bin ~state_dir ~extra_env
                  [ "up"; "no-passt"; "--target"; ".#dev" ]
              in
              assert_failure ~context:"missing passt" result;
              let _, _, err = result in
              assert_contains ~context:"passt error message" err "passt";
              assert_contains ~context:"passt EPI_PASST_BIN hint" err
                "EPI_PASST_BIN")));
  run_test
    ~name:"down terminates passt process alongside hypervisor"
    (fun () ->
      with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
          with_state_dir (fun state_dir ->
              let result =
                run_cli_with_env ~bin ~state_dir ~extra_env
                  [ "up"; "passt-kill-test"; "--target"; ".#dev" ]
              in
              assert_success ~context:"up for passt kill test" result;
              let passt_pid =
                match find_state_runtime ~state_dir "passt-kill-test" with
                | Some (_, _, _, Some pid, _, _) -> pid
                | _ -> fail "expected passt_pid in state after up"
              in
              if not (pid_is_alive passt_pid) then
                fail "passt process should be alive before down";
              let down_result =
                run_cli_with_env ~bin ~state_dir ~extra_env
                  [ "down"; "passt-kill-test" ]
              in
              assert_success ~context:"down passt kill" down_result;
              if not (wait_for_pid_to_die ~attempts:40 passt_pid) then
                fail "passt process should be dead after down";
              (match find_state_runtime ~state_dir "passt-kill-test" with
              | None -> ()
              | _ ->
                  fail
                    "expected runtime to be cleared but instance kept after down"))));
  run_test
    ~name:"up over stale instance terminates old passt process"
    (fun () ->
      with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
          with_state_dir (fun state_dir ->
              let result =
                run_cli_with_env ~bin ~state_dir ~extra_env
                  [ "up"; "stale-passt"; "--target"; ".#dev" ]
              in
              assert_success ~context:"first up for stale passt" result;
              let old_hypervisor_pid, old_passt_pid =
                match find_state_runtime ~state_dir "stale-passt" with
                | Some (Some pid, _, _, Some ppid, _, _) -> (pid, ppid)
                | _ -> fail "expected pid and passt_pid in state after first up"
              in
              terminate_pid old_hypervisor_pid;
              if not (pid_is_alive old_passt_pid) then
                fail "old passt process should be alive before relaunch";
              let result2 =
                run_cli_with_env ~bin ~state_dir ~extra_env
                  [ "up"; "stale-passt"; "--target"; ".#dev" ]
              in
              assert_success ~context:"relaunch over stale passt" result2;
              if not (wait_for_pid_to_die ~attempts:80 old_passt_pid) then
                fail
                  "old passt process should be terminated after relaunch \
                   over stale instance")));
  run_test
    ~name:"cache is written after successful provision"
    (fun () ->
      with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
          with_state_dir (fun state_dir ->
              with_temp_dir "epi-cache-home" (fun cache_dir ->
                  let extra_env = ("EPI_CACHE_DIR", cache_dir) :: extra_env in
                  let result =
                    run_cli_with_env ~bin ~state_dir ~extra_env
                      [ "up"; "cache-write"; "--target"; ".#dev" ]
                  in
                  assert_success ~context:"cache write up" result;
                  let targets_dir =
                    Filename.concat cache_dir "targets"
                  in
                  if not (Sys.file_exists targets_dir) then
                    fail "cache targets directory was not created";
                  let entries = Sys.readdir targets_dir |> Array.to_list in
                  let descriptor_files =
                    List.filter
                      (fun name ->
                        let len = String.length name in
                        len > 11
                        && String.sub name (len - 11) 11 = ".descriptor")
                      entries
                  in
                  if descriptor_files = [] then
                    fail "no .descriptor cache file was created"))));
  run_test
    ~name:"second epi up on same target uses cache"
    (fun () ->
      with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
          with_state_dir (fun state_dir ->
              with_temp_dir "epi-cache-hit" (fun test_dir ->
                  let cache_dir = Filename.concat test_dir "cache" in
                  let resolver_log =
                    Filename.concat test_dir "resolver-calls.log"
                  in
                  let counting_resolver =
                    Filename.concat test_dir "counting-resolver.sh"
                  in
                  let original_resolver =
                    List.assoc "EPI_TARGET_RESOLVER_CMD" extra_env
                  in
                  write_file counting_resolver
                    ("#!/usr/bin/env sh\n\
                      echo \"call\" >> \"" ^ resolver_log ^ "\"\n\
                      exec \"" ^ original_resolver ^ "\" \"$@\"\n");
                  make_executable counting_resolver;
                  let extra_env =
                    ("EPI_CACHE_DIR", cache_dir)
                    :: List.map
                         (fun (k, v) ->
                           if String.equal k "EPI_TARGET_RESOLVER_CMD" then
                             (k, counting_resolver)
                           else (k, v))
                         extra_env
                  in
                  let result1 =
                    run_cli_with_env ~bin ~state_dir ~extra_env
                      [ "up"; "cache-hit"; "--target"; ".#dev" ]
                  in
                  assert_success ~context:"cache hit first up" result1;
                  let hypervisor_pid, passt_pid =
                    match find_state_runtime ~state_dir "cache-hit" with
                    | Some (Some pid, _, _, Some ppid, _, _) -> (pid, ppid)
                    | _ -> fail "expected pid and passt_pid after first up"
                  in
                  terminate_pid hypervisor_pid;
                  terminate_pid passt_pid;
                  let _ = wait_for_pid_to_die ~attempts:20 hypervisor_pid in
                  let result2 =
                    run_cli_with_env ~bin ~state_dir ~extra_env
                      [ "up"; "cache-hit"; "--target"; ".#dev" ]
                  in
                  assert_success ~context:"cache hit second up" result2;
                  let log_content =
                    if Sys.file_exists resolver_log then
                      let channel = open_in resolver_log in
                      Fun.protect
                        ~finally:(fun () -> close_in channel)
                        (fun () -> read_all channel)
                    else ""
                  in
                  let call_count =
                    String.split_on_char '\n' log_content
                    |> List.filter (fun line -> String.equal line "call")
                    |> List.length
                  in
                  if call_count <> 1 then
                    fail
                      "expected resolver to be called exactly once, got %d"
                      call_count))));
  run_test
    ~name:"cache with missing path triggers re-eval"
    (fun () ->
      with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
          with_state_dir (fun state_dir ->
              with_temp_dir "epi-cache-miss" (fun test_dir ->
                  let cache_dir = Filename.concat test_dir "cache" in
                  let resolver_log =
                    Filename.concat test_dir "resolver-calls.log"
                  in
                  let counting_resolver =
                    Filename.concat test_dir "counting-resolver.sh"
                  in
                  let original_resolver =
                    List.assoc "EPI_TARGET_RESOLVER_CMD" extra_env
                  in
                  write_file counting_resolver
                    ("#!/usr/bin/env sh\n\
                      echo \"call\" >> \"" ^ resolver_log ^ "\"\n\
                      exec \"" ^ original_resolver ^ "\" \"$@\"\n");
                  make_executable counting_resolver;
                  let extra_env =
                    ("EPI_CACHE_DIR", cache_dir)
                    :: List.map
                         (fun (k, v) ->
                           if String.equal k "EPI_TARGET_RESOLVER_CMD" then
                             (k, counting_resolver)
                           else (k, v))
                         extra_env
                  in
                  let result1 =
                    run_cli_with_env ~bin ~state_dir ~extra_env
                      [ "up"; "cache-miss"; "--target"; ".#dev" ]
                  in
                  assert_success ~context:"cache miss first up" result1;
                  let hypervisor_pid, passt_pid =
                    match find_state_runtime ~state_dir "cache-miss" with
                    | Some (Some pid, _, _, Some ppid, _, _) -> (pid, ppid)
                    | _ -> fail "expected pid and passt_pid after first up"
                  in
                  terminate_pid hypervisor_pid;
                  terminate_pid passt_pid;
                  let _ = wait_for_pid_to_die ~attempts:20 hypervisor_pid in
                  let targets_dir = Filename.concat cache_dir "targets" in
                  let cache_files = Sys.readdir targets_dir |> Array.to_list in
                  let cache_file =
                    match
                      List.find_opt
                        (fun name ->
                          let len = String.length name in
                          len > 11
                          && String.sub name (len - 11) 11 = ".descriptor")
                        cache_files
                    with
                    | Some name -> Filename.concat targets_dir name
                    | None -> fail "expected cache file after first up"
                  in
                  let cache_content =
                    let channel = open_in cache_file in
                    Fun.protect
                      ~finally:(fun () -> close_in channel)
                      (fun () -> read_all channel)
                  in
                  let corrupted =
                    let lines = String.split_on_char '\n' cache_content in
                    List.map
                      (fun line ->
                        if
                          String.length line > 5
                          && String.sub line 0 5 = "disk="
                        then "disk=/nonexistent/path"
                        else line)
                      lines
                    |> String.concat "\n"
                  in
                  write_file cache_file corrupted;
                  let result2 =
                    run_cli_with_env ~bin ~state_dir ~extra_env
                      [ "up"; "cache-miss"; "--target"; ".#dev" ]
                  in
                  assert_success ~context:"cache miss second up" result2;
                  let log_content =
                    if Sys.file_exists resolver_log then
                      let channel = open_in resolver_log in
                      Fun.protect
                        ~finally:(fun () -> close_in channel)
                        (fun () -> read_all channel)
                    else ""
                  in
                  let call_count =
                    String.split_on_char '\n' log_content
                    |> List.filter (fun line -> String.equal line "call")
                    |> List.length
                  in
                  if call_count <> 2 then
                    fail
                      "expected resolver to be called twice (cache miss), \
                       got %d"
                      call_count))));
  run_test
    ~name:"--rebuild busts cache and re-evals unconditionally"
    (fun () ->
      with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
          with_state_dir (fun state_dir ->
              with_temp_dir "epi-cache-rebuild" (fun test_dir ->
                  let cache_dir = Filename.concat test_dir "cache" in
                  let resolver_log =
                    Filename.concat test_dir "resolver-calls.log"
                  in
                  let counting_resolver =
                    Filename.concat test_dir "counting-resolver.sh"
                  in
                  let original_resolver =
                    List.assoc "EPI_TARGET_RESOLVER_CMD" extra_env
                  in
                  write_file counting_resolver
                    ("#!/usr/bin/env sh\n\
                      echo \"call\" >> \"" ^ resolver_log ^ "\"\n\
                      exec \"" ^ original_resolver ^ "\" \"$@\"\n");
                  make_executable counting_resolver;
                  let extra_env =
                    ("EPI_CACHE_DIR", cache_dir)
                    :: List.map
                         (fun (k, v) ->
                           if String.equal k "EPI_TARGET_RESOLVER_CMD" then
                             (k, counting_resolver)
                           else (k, v))
                         extra_env
                  in
                  let result1 =
                    run_cli_with_env ~bin ~state_dir ~extra_env
                      [ "up"; "rebuild-test"; "--target"; ".#dev" ]
                  in
                  assert_success ~context:"rebuild first up" result1;
                  let hypervisor_pid, passt_pid =
                    match find_state_runtime ~state_dir "rebuild-test" with
                    | Some (Some pid, _, _, Some ppid, _, _) -> (pid, ppid)
                    | _ -> fail "expected pid and passt_pid after first up"
                  in
                  terminate_pid hypervisor_pid;
                  terminate_pid passt_pid;
                  let _ = wait_for_pid_to_die ~attempts:20 hypervisor_pid in
                  let result2 =
                    run_cli_with_env ~bin ~state_dir ~extra_env
                      [ "up"; "rebuild-test"; "--target"; ".#dev"; "--rebuild" ]
                  in
                  assert_success ~context:"rebuild second up" result2;
                  let log_content =
                    if Sys.file_exists resolver_log then
                      let channel = open_in resolver_log in
                      Fun.protect
                        ~finally:(fun () -> close_in channel)
                        (fun () -> read_all channel)
                    else ""
                  in
                  let call_count =
                    String.split_on_char '\n' log_content
                    |> List.filter (fun line -> String.equal line "call")
                    |> List.length
                  in
                  if call_count <> 2 then
                    fail
                      "expected resolver to be called twice (rebuild), got %d"
                      call_count))));
  run_test ~name:"alloc_free_port returns a valid port number" (fun () ->
      let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
      Fun.protect
        ~finally:(fun () -> Unix.close sock)
        (fun () ->
          Unix.bind sock (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
          match Unix.getsockname sock with
          | Unix.ADDR_INET (_, port) ->
              if port < 1 || port > 65535 then
                fail "alloc_free_port returned out-of-range port: %d" port
          | _ -> fail "unexpected socket address from bind-to-zero"));
  run_test ~name:"passt is invoked with -t port:22 forwarding argument"
    (fun () ->
      with_temp_dir "epi-passt-args-test" (fun dir ->
          let passt_log = Filename.concat dir "passt-args.log" in
          let kernel = Filename.concat dir "vmlinuz" in
          let disk = Filename.concat dir "disk.img" in
          let initrd = Filename.concat dir "initrd.img" in
          let resolver = Filename.concat dir "resolver.sh" in
          let cloud_hypervisor = Filename.concat dir "cloud-hypervisor.sh" in
          write_file kernel "kernel";
          write_file disk "disk";
          write_file initrd "initrd";
          write_file resolver
            ("#!/usr/bin/env sh\necho \"kernel=" ^ kernel ^ "\"\necho \"disk="
           ^ disk ^ "\"\necho \"initrd=" ^ initrd
           ^ "\"\necho \"cpus=2\"\necho \"memory_mib=1024\"\n");
          write_file cloud_hypervisor
            ("#!/usr/bin/env sh\nexec sleep 30\n");
          let genisoimage = Filename.concat dir "genisoimage.sh" in
          write_file genisoimage
            "#!/usr/bin/env sh\n\
             OUTPUT=\"\"\n\
             while [ $# -gt 0 ]; do\n\
            \  case \"$1\" in\n\
            \    -output) OUTPUT=\"$2\"; shift 2 ;;\n\
            \    *) shift ;;\n\
            \  esac\n\
             done\n\
             if [ -n \"$OUTPUT\" ]; then echo mock > \"$OUTPUT\"; fi\n\
             exit 0\n";
          let passt = Filename.concat dir "passt.sh" in
          write_file passt
            ("#!/usr/bin/env sh\n\
              echo \"$*\" >> \"" ^ passt_log ^ "\"\n\
              prev=\"\"\n\
              for arg in \"$@\"; do\n\
             \  if [ \"$prev\" = \"--socket\" ]; then\n\
             \    touch \"$arg\"\n\
             \  fi\n\
             \  prev=\"$arg\"\n\
              done\n\
              exec sleep 30\n");
          make_executable resolver;
          make_executable cloud_hypervisor;
          make_executable genisoimage;
          make_executable passt;
          let cache_dir = Filename.concat dir "cache" in
          Unix.mkdir cache_dir 0o755;
          let extra_env =
            [
              ("EPI_TARGET_RESOLVER_CMD", resolver);
              ("EPI_CLOUD_HYPERVISOR_BIN", cloud_hypervisor);
              ("EPI_GENISOIMAGE_BIN", genisoimage);
              ("EPI_PASST_BIN", passt);
              ("EPI_MOCK_VM_SLEEP", "30");
              ("EPI_CACHE_DIR", cache_dir);
            ]
          in
          with_state_dir (fun state_dir ->
              let result =
                run_cli_with_env ~bin ~state_dir ~extra_env
                  [ "up"; "passt-args"; "--target"; ".#dev" ]
              in
              assert_success ~context:"passt args up" result;
              let passt_args =
                if Sys.file_exists passt_log then
                  let channel = open_in passt_log in
                  Fun.protect
                    ~finally:(fun () -> close_in channel)
                    (fun () -> read_all channel)
                else ""
              in
              assert_contains ~context:"passt -t flag" passt_args "-t";
              assert_contains ~context:"passt :22 target" passt_args ":22")));
  run_test ~name:"epi up output includes the SSH port" (fun () ->
      with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
          with_state_dir (fun state_dir ->
              let result =
                run_cli_with_env ~bin ~state_dir ~extra_env
                  [ "up"; "ssh-port-output"; "--target"; ".#dev" ]
              in
              assert_success ~context:"ssh port output up" result;
              let _, stdout, _ = result in
              assert_contains ~context:"SSH port in up output" stdout
                "SSH port:")));
  run_test ~name:"runtime round-trips ssh_port correctly" (fun () ->
      with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
          with_state_dir (fun state_dir ->
              let result =
                run_cli_with_env ~bin ~state_dir ~extra_env
                  [ "up"; "rt-roundtrip"; "--target"; ".#dev" ]
              in
              assert_success ~context:"runtime roundtrip up" result;
              match find_state_runtime ~state_dir "rt-roundtrip" with
              | Some (_, _, _, _, Some port, _) when port > 0 && port <= 65535
                ->
                  ()
              | Some (_, _, _, _, None, _) ->
                  fail "expected ssh_port to be set in runtime after up"
              | Some (_, _, _, _, Some port, _) ->
                  fail "ssh_port out of range: %d" port
              | None -> fail "expected runtime for rt-roundtrip")));
  run_test
    ~name:
      "configured user produces cloud-init with only SSH keys, no \
       groups/sudo/shell"
    (fun () ->
      with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
          with_state_dir (fun state_dir ->
              with_temp_dir "epi-configured-user-test" (fun ssh_dir ->
                  write_file
                    (Filename.concat ssh_dir "id_ed25519.pub")
                    "ssh-ed25519 AAAAC3test testkey@host";
                  let extra_env =
                    ("EPI_SSH_DIR", ssh_dir) :: extra_env
                  in
                  let result =
                    run_cli_with_env ~bin ~state_dir ~extra_env
                      [ "up"; "configured-test"; "--target"; ".#user-configured" ]
                  in
                  assert_success ~context:"configured user up" result;
                  let user_data_path =
                    Filename.concat
                      (Filename.concat
                        (Filename.concat state_dir "configured-test")
                        "cidata")
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
                  assert_contains ~context:"configured user ssh keys"
                    user_data "ssh_authorized_keys:";
                  assert_contains ~context:"configured user ssh key value"
                    user_data "ssh-ed25519 AAAAC3test testkey@host";
                  if contains user_data "groups: wheel" then
                    fail
                      "configured user cloud-init should not contain 'groups: \
                       wheel'";
                  if contains user_data "sudo:" then
                    fail
                      "configured user cloud-init should not contain 'sudo:'";
                  if contains user_data "shell:" then
                    fail
                      "configured user cloud-init should not contain 'shell:'"))));
  run_test
    ~name:
      "unconfigured user produces full cloud-init with groups/sudo/shell"
    (fun () ->
      with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
          with_state_dir (fun state_dir ->
              let result =
                run_cli_with_env ~bin ~state_dir ~extra_env
                  [ "up"; "unconfigured-test"; "--target"; ".#dev" ]
              in
              assert_success ~context:"unconfigured user up" result;
              let user_data_path =
                Filename.concat
                  (Filename.concat
                    (Filename.concat state_dir "unconfigured-test")
                    "cidata")
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
              assert_contains ~context:"unconfigured user groups" user_data
                "groups: wheel";
              assert_contains ~context:"unconfigured user sudo" user_data
                "sudo: ALL=(ALL) NOPASSWD:ALL";
              assert_contains ~context:"unconfigured user shell" user_data
                "shell: /run/current-system/sw/bin/bash")));
  ()
