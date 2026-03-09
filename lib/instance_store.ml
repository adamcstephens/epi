let default_instance_name = "default"

type runtime = {
  unit_id : string;
  serial_socket : string;
  disk : string;
  ssh_port : int option;
  ssh_key_path : string option;
}

let make_absolute path =
  if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path
  else path

let state_dir () =
  let dir =
    match Sys.getenv_opt "EPI_STATE_DIR" with
    | Some dir -> dir
    | None -> (
        match Sys.getenv_opt "HOME" with
        | Some home -> Filename.concat home ".local/state/epi"
        | None -> ".epi-state")
  in
  make_absolute dir

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
  Printf.fprintf channel "unit_id=%s\n" rt.unit_id;
  Printf.fprintf channel "serial_socket=%s\n" rt.serial_socket;
  Printf.fprintf channel "disk=%s\n" rt.disk;
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
    match get "unit_id" with
    | Some unit_id when unit_id <> "" ->
        let serial_socket = Option.value ~default:"" (get "serial_socket") in
        let disk = Option.value ~default:"" (get "disk") in
        let ssh_port = get_int "ssh_port" in
        let ssh_key_path = get "ssh_key_path" in
        Some { unit_id; serial_socket; disk; ssh_port; ssh_key_path }
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

let vm_unit_name ~instance_name ~unit_id =
  let escaped = Process.escape_unit_name instance_name in
  Printf.sprintf "epi-%s-%s-vm.service" escaped unit_id

let slice_name ~instance_name ~unit_id =
  let escaped = Process.escape_unit_name instance_name in
  Printf.sprintf "epi-%s-%s.slice" escaped unit_id

let instance_is_running instance_name =
  match load_runtime instance_name with
  | Some runtime ->
      Process.unit_is_active (vm_unit_name ~instance_name ~unit_id:runtime.unit_id)
  | None -> false

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
        | Some ({ disk = runtime_disk; unit_id; _ } as instance_runtime)
          when String.equal runtime_disk disk
               && Process.unit_is_active (vm_unit_name ~instance_name:name ~unit_id) ->
            Some (name, instance_runtime)
        | _ -> None)
