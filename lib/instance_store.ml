let default_instance_name = "default"

type runtime = {
  unit_id : string;
  serial_socket : string;
  disk : string;
  ssh_port : int option;
  ssh_key_path : string;
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

let instance_dir instance_name = Filename.concat (state_dir ()) instance_name

let instance_path instance_name filename =
  Filename.concat (instance_dir instance_name) filename

let serial_socket_path instance_name = instance_path instance_name "serial.sock"

let ensure_instance_dir instance_name =
  Util.ensure_dir (instance_dir instance_name)

let state_json_path instance_name = instance_path instance_name "state.json"

let runtime_to_json (rt : runtime) =
  let fields =
    [
      ("unit_id", `String rt.unit_id);
      ("serial_socket", `String rt.serial_socket);
      ("disk", `String rt.disk);
    ]
    @ (match rt.ssh_port with Some p -> [ ("ssh_port", `Int p) ] | None -> [])
    @ [ ("ssh_key_path", `String rt.ssh_key_path) ]
  in
  `Assoc fields

let runtime_of_json json =
  let open Yojson.Basic.Util in
  let unit_id = json |> member "unit_id" |> to_string_option in
  let ssh_key_path = json |> member "ssh_key_path" |> to_string_option in
  match (unit_id, ssh_key_path) with
  | Some unit_id, Some ssh_key_path when unit_id <> "" && ssh_key_path <> "" ->
      Some
        {
          unit_id;
          serial_socket =
            json |> member "serial_socket" |> to_string_option
            |> Option.value ~default:"";
          disk =
            json |> member "disk" |> to_string_option
            |> Option.value ~default:"";
          ssh_port = json |> member "ssh_port" |> to_int_option;
          ssh_key_path;
        }
  | _ -> None

let load_state_json instance_name =
  let path = state_json_path instance_name in
  match Util.read_file path with
  | None -> None
  | Some content -> (
      match Yojson.Basic.from_string content with
      | json -> Some json
      | exception Yojson.Json_error _ -> None)

let save_state_json instance_name json =
  ensure_instance_dir instance_name;
  let path = state_json_path instance_name in
  let content = Yojson.Basic.pretty_to_string json ^ "\n" in
  let channel = open_out path in
  output_string channel content;
  close_out channel

let save_target instance_name target =
  let base =
    match load_state_json instance_name with Some j -> j | None -> `Assoc []
  in
  let fields = match base with `Assoc fs -> fs | _ -> [] in
  let fields = List.filter (fun (k, _) -> k <> "target") fields in
  save_state_json instance_name (`Assoc (("target", `String target) :: fields))

let load_target instance_name =
  match load_state_json instance_name with
  | Some json -> (
      let open Yojson.Basic.Util in
      match json |> member "target" |> to_string_option with
      | Some s when s <> "" -> Some s
      | _ -> None)
  | None -> None

let save_runtime instance_name (rt : runtime) =
  let base =
    match load_state_json instance_name with Some j -> j | None -> `Assoc []
  in
  let fields = match base with `Assoc fs -> fs | _ -> [] in
  let fields = List.filter (fun (k, _) -> k <> "runtime") fields in
  save_state_json instance_name
    (`Assoc (fields @ [ ("runtime", runtime_to_json rt) ]))

let load_runtime instance_name =
  match load_state_json instance_name with
  | Some json -> (
      let open Yojson.Basic.Util in
      match json |> member "runtime" with
      | `Null -> None
      | rt -> runtime_of_json rt)
  | None -> None

let save_mounts instance_name paths =
  let base =
    match load_state_json instance_name with Some j -> j | None -> `Assoc []
  in
  let fields = match base with `Assoc fs -> fs | _ -> [] in
  let fields = List.filter (fun (k, _) -> k <> "mounts") fields in
  let mounts = `List (List.map (fun p -> `String p) paths) in
  save_state_json instance_name (`Assoc (fields @ [ ("mounts", mounts) ]))

let load_mounts instance_name =
  match load_state_json instance_name with
  | Some json -> (
      let open Yojson.Basic.Util in
      match json |> member "mounts" with
      | `Null -> []
      | mounts -> mounts |> to_list |> List.filter_map to_string_option)
  | None -> []

let set ~instance_name ~target =
  let base =
    match load_state_json instance_name with Some j -> j | None -> `Assoc []
  in
  let fields = match base with `Assoc fs -> fs | _ -> [] in
  let fields =
    List.filter (fun (k, _) -> k <> "target" && k <> "runtime") fields
  in
  save_state_json instance_name (`Assoc (("target", `String target) :: fields))

let set_provisioned ~instance_name ~target ~runtime =
  save_target instance_name target;
  save_runtime instance_name runtime

let find instance_name = load_target instance_name
let find_runtime instance_name = load_runtime instance_name

let list () =
  let dir = state_dir () in
  if not (Sys.file_exists dir) then []
  else
    Sys.readdir dir |> Array.to_list
    |> List.filter (fun name ->
        let d = Filename.concat dir name in
        Sys.is_directory d && Sys.file_exists (Filename.concat d "state.json"))
    |> List.filter_map (fun name ->
        match load_target name with
        | Some target -> Some (name, target)
        | None -> None)
    |> List.sort (fun (a, _) (b, _) -> String.compare a b)

let clear_runtime instance_name =
  match load_state_json instance_name with
  | Some (`Assoc fields) ->
      let fields = List.filter (fun (k, _) -> k <> "runtime") fields in
      save_state_json instance_name (`Assoc fields)
  | _ -> ()

let remove_tree path =
  let rec walk p =
    if Sys.file_exists p then
      if Sys.is_directory p then (
        Sys.readdir p |> Array.iter (fun name -> walk (Filename.concat p name));
        Unix.rmdir p)
      else Sys.remove p
  in
  walk path

let remove instance_name =
  let dir = instance_dir instance_name in
  if Sys.file_exists dir then remove_tree dir

let vm_unit_name ~instance_name ~unit_id =
  let ( let* ) = Result.bind in
  let* escaped = Process.escape_unit_name instance_name in
  Ok (Printf.sprintf "epi-%s_%s_vm.service" escaped unit_id)

let slice_name ~instance_name ~unit_id =
  let ( let* ) = Result.bind in
  let* escaped = Process.escape_unit_name instance_name in
  Ok (Printf.sprintf "epi-%s_%s.slice" escaped unit_id)

let instance_is_running instance_name =
  match load_runtime instance_name with
  | Some runtime -> (
      match vm_unit_name ~instance_name ~unit_id:runtime.unit_id with
      | Ok unit_name -> Process.unit_is_active unit_name
      | Error _ -> false)
  | None -> false

let find_running_owner_by_disk disk =
  let dir = state_dir () in
  if not (Sys.file_exists dir) then None
  else
    Sys.readdir dir |> Array.to_list
    |> List.filter (fun name -> Sys.is_directory (Filename.concat dir name))
    |> List.find_map (fun name ->
        match load_runtime name with
        | Some ({ disk = runtime_disk; unit_id; _ } as instance_runtime)
          when String.equal runtime_disk disk
               &&
               match vm_unit_name ~instance_name:name ~unit_id with
               | Ok unit_name -> Process.unit_is_active unit_name
               | Error _ -> false ->
            Some (name, instance_runtime)
        | _ -> None)
