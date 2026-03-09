let default_instance_name = "default"

type runtime = {
  pid : int;
  serial_socket : string;
  disk : string;
  passt_pid : int option;
  virtiofsd_pids : int list;
  ssh_port : int option;
  ssh_key_path : string option;
}

let state_dir () =
  match Sys.getenv_opt "EPI_STATE_DIR" with
  | Some dir -> dir
  | None -> (
      match Sys.getenv_opt "HOME" with
      | Some home -> Filename.concat home ".local/state/epi"
      | None -> ".epi-state")

let ensure_parent_dir path =
  let dir = Filename.dirname path in
  let rec make_dir current =
    if current = "." || current = "/" || current = "" then ()
    else if Sys.file_exists current then ()
    else (
      make_dir (Filename.dirname current);
      Unix.mkdir current 0o755)
  in
  make_dir dir

let instance_dir instance_name = Filename.concat (state_dir ()) instance_name
let instance_path instance_name filename =
  Filename.concat (instance_dir instance_name) filename

let serial_socket_path instance_name = instance_path instance_name "serial.sock"
let launch_stdout_path instance_name = instance_path instance_name "stdout.log"
let launch_stderr_path instance_name = instance_path instance_name "stderr.log"

let ensure_instance_dir instance_name =
  let dir = instance_dir instance_name in
  let rec make_dir current =
    if current = "." || current = "/" || current = "" then ()
    else if Sys.file_exists current then ()
    else (
      make_dir (Filename.dirname current);
      Unix.mkdir current 0o755)
  in
  make_dir dir

let save_target instance_name target =
  ensure_instance_dir instance_name;
  let path = instance_path instance_name "target" in
  let channel = open_out path in
  output_string channel target;
  output_char channel '\n';
  close_out channel

let load_target instance_name =
  let path = instance_path instance_name "target" in
  let content = Target.read_file_if_exists path in
  let trimmed = String.trim content in
  if trimmed = "" then None else Some trimmed

let save_runtime instance_name (rt : runtime) =
  ensure_instance_dir instance_name;
  let path = instance_path instance_name "runtime" in
  let channel = open_out path in
  Printf.fprintf channel "pid=%d\n" rt.pid;
  Printf.fprintf channel "serial_socket=%s\n" rt.serial_socket;
  Printf.fprintf channel "disk=%s\n" rt.disk;
  (match rt.passt_pid with
  | Some p -> Printf.fprintf channel "passt_pid=%d\n" p
  | None -> ());
  (match rt.virtiofsd_pids with
  | [] -> ()
  | pids ->
      Printf.fprintf channel "virtiofsd_pids=%s\n"
        (String.concat "," (List.map string_of_int pids)));
  (match rt.ssh_port with
  | Some p -> Printf.fprintf channel "ssh_port=%d\n" p
  | None -> ());
  (match rt.ssh_key_path with
  | Some p -> Printf.fprintf channel "ssh_key_path=%s\n" p
  | None -> ());
  close_out channel

let load_runtime instance_name =
  let path = instance_path instance_name "runtime" in
  let content = Target.read_file_if_exists path in
  if String.trim content = "" then None
  else
    let pairs = Target.parse_key_value_output content in
    let get key = List.assoc_opt key pairs in
    let get_int key =
      match get key with
      | Some v -> int_of_string_opt v
      | None -> None
    in
    match get_int "pid" with
    | Some pid when pid > 0 ->
        let serial_socket = Option.value ~default:"" (get "serial_socket") in
        let disk = Option.value ~default:"" (get "disk") in
        let passt_pid = get_int "passt_pid" in
        let virtiofsd_pids =
          match get "virtiofsd_pids" with
          | Some s -> String.split_on_char ',' s |> List.filter_map int_of_string_opt
          | None -> (match get_int "virtiofsd_pid" with Some p -> [ p ] | None -> [])
        in
        let ssh_port = get_int "ssh_port" in
        let ssh_key_path = get "ssh_key_path" in
        Some { pid; serial_socket; disk; passt_pid; virtiofsd_pids; ssh_port; ssh_key_path }
    | _ -> None

let save_mounts instance_name paths =
  ensure_instance_dir instance_name;
  let path = instance_path instance_name "mounts" in
  let channel = open_out path in
  List.iter (fun p ->
      output_string channel p;
      output_char channel '\n')
    paths;
  close_out channel

let load_mounts instance_name =
  let path = instance_path instance_name "mounts" in
  let content = Target.read_file_if_exists path in
  if String.trim content = "" then []
  else
    String.split_on_char '\n' content
    |> List.map String.trim
    |> List.filter (fun s -> s <> "")

let set ~instance_name ~target =
  save_target instance_name target;
  let runtime_path = instance_path instance_name "runtime" in
  if Sys.file_exists runtime_path then Sys.remove runtime_path

let set_provisioned ~instance_name ~target ~runtime =
  save_target instance_name target;
  save_runtime instance_name runtime

let find instance_name = load_target instance_name

let find_runtime instance_name = load_runtime instance_name

let list () =
  let dir = state_dir () in
  if not (Sys.file_exists dir) then []
  else
    Sys.readdir dir
    |> Array.to_list
    |> List.filter (fun name ->
        let d = Filename.concat dir name in
        Sys.is_directory d
        && Sys.file_exists (Filename.concat d "target"))
    |> List.filter_map (fun name ->
        match load_target name with
        | Some target -> Some (name, target)
        | None -> None)
    |> List.sort (fun (a, _) (b, _) -> String.compare a b)

let clear_runtime instance_name =
  let path = instance_path instance_name "runtime" in
  if Sys.file_exists path then Sys.remove path

let remove_tree path =
  let rec walk p =
    if Sys.file_exists p then
      if Sys.is_directory p then (
        Sys.readdir p
        |> Array.iter (fun name -> walk (Filename.concat p name));
        Unix.rmdir p)
      else Sys.remove p
  in
  walk path

let remove instance_name =
  let dir = instance_dir instance_name in
  if Sys.file_exists dir then remove_tree dir

let find_running_owner_by_disk disk =
  let dir = state_dir () in
  if not (Sys.file_exists dir) then None
  else
    Sys.readdir dir
    |> Array.to_list
    |> List.filter (fun name ->
        Sys.is_directory (Filename.concat dir name))
    |> List.find_map (fun name ->
        match load_runtime name with
        | Some ({ pid; disk = runtime_disk; _ } as instance_runtime)
          when String.equal runtime_disk disk && Process.pid_is_alive pid ->
            Some (name, instance_runtime)
        | _ -> None)

let kill_if_alive pid =
  try Unix.kill pid Sys.sigterm with Unix.Unix_error (Unix.ESRCH, _, _) -> ()

let reconcile_runtime () =
  let dir = state_dir () in
  if not (Sys.file_exists dir) then ()
  else
    Sys.readdir dir
    |> Array.iter (fun name ->
        let d = Filename.concat dir name in
        if Sys.is_directory d then
          match load_runtime name with
          | Some { pid; serial_socket; passt_pid; virtiofsd_pids; _ }
            when not (Process.pid_is_alive pid) ->
              (match passt_pid with
              | Some passt_pid -> kill_if_alive passt_pid
              | None -> ());
              List.iter kill_if_alive virtiofsd_pids;
              if Sys.file_exists serial_socket then Unix.unlink serial_socket;
              clear_runtime name
          | _ -> ())
