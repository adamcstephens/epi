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

let read_file path = In_channel.with_open_text path In_channel.input_all

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
  let stdout = In_channel.input_all stdout_channel in
  let stderr = In_channel.input_all stderr_channel in
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

let write_file path content =
  let channel = open_out path in
  output_string channel content;
  close_out channel

let write_state_entry ~state_dir ~instance_name ~target ?pid ?serial_socket
    ?disk ?passt_pid ?virtiofsd_pid ?ssh_port ?ssh_key_path () =
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
      (match virtiofsd_pid with
      | Some p -> Printf.fprintf channel "virtiofsd_pid=%d\n" p
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
    let content = read_file runtime_path in
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
          get_int "passt_pid", get_int "virtiofsd_pid",
          get_int "ssh_port", get "ssh_key_path")

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
          | Some (pid, _, _, passt_pid, virtiofsd_pid, _, _) ->
              (match pid with Some p -> terminate_pid p | None -> ());
              (match passt_pid with Some p -> terminate_pid p | None -> ());
              (match virtiofsd_pid with Some p -> terminate_pid p | None -> ())
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

let with_sleep_process f =
  match Unix.fork () with
  | 0 ->
      Unix.sleep 30;
      exit 0
  | pid -> Fun.protect ~finally:(fun () -> terminate_pid pid) (fun () -> f pid)
