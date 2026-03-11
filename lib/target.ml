type t = string

let to_string target = target

let of_string target =
  match String.split_on_char '#' target with
  | [ flake_ref; config_name ] when flake_ref = "" || config_name = "" ->
      Error
        (`Msg
           "both flake reference and config name are required in --target \
            <flake-ref>#<config-name>")
  | [ _flake_ref; _config_name ] -> Ok target
  | _ -> Error (`Msg "--target must use <flake-ref>#<config-name>")

type hooks_config = {
  post_launch : string list;
  pre_stop : string list;
}

type descriptor = {
  kernel : string;
  disk : string;
  initrd : string option;
  cmdline : string;
  cpus : int;
  memory_mib : int;
  configured_users : string list;
  hooks : hooks_config;
}

let default_cmdline = "console=ttyS0 root=/dev/vda2 ro"


let descriptor_of_json json =
  let open Yojson.Basic.Util in
  let str key default = json |> member key |> to_string_option |> Option.value ~default in
  let int key default = json |> member key |> to_int_option |> Option.value ~default in
  let kernel = str "kernel" "" in
  let disk = str "disk" "" in
  let initrd = json |> member "initrd" |> to_string_option in
  let cmdline = str "cmdline" default_cmdline in
  let cpus = int "cpus" 1 in
  let memory_mib = int "memory_mib" 1024 in
  let configured_users =
    match json |> member "configuredUsers" with
    | `List items -> List.filter_map to_string_option items
    | _ -> []
  in
  let parse_hook_set hooks_json key =
    match hooks_json |> member key with
    | `Assoc pairs ->
        pairs
        |> List.sort (fun (k1, _) (k2, _) -> String.compare k1 k2)
        |> List.filter_map (fun (_, v) -> to_string_option v)
    | `List items -> List.filter_map to_string_option items
    | _ -> []
  in
  let hooks =
    match json |> member "hooks" with
    | `Assoc _ as hooks_json ->
        { post_launch = parse_hook_set hooks_json "post-launch";
          pre_stop = parse_hook_set hooks_json "pre-stop" }
    | _ -> { post_launch = []; pre_stop = [] }
  in
  { kernel; disk; initrd; cmdline; cpus; memory_mib; configured_users; hooks }

type resolution_error = {
  target : string;
  details : string;
  exit_code : int option;
}

let expand_flake_ref_tilde target =
  match String.index_opt target '#' with
  | None -> Config.expand_tilde target
  | Some i ->
      let flake_ref = String.sub target 0 i in
      let rest = String.sub target i (String.length target - i) in
      Config.expand_tilde flake_ref ^ rest

let store_root_of_path path =
  let prefix = "/nix/store/" in
  if not (String.starts_with ~prefix path) then None
  else
    let rest =
      String.sub path (String.length prefix)
        (String.length path - String.length prefix)
    in
    match String.index_opt rest '/' with
    | None -> Some path
    | Some index -> Some (prefix ^ String.sub rest 0 index)

let ensure_store_realized path =
  match store_root_of_path path with
  | None -> ()
  | Some store_root ->
      if Sys.file_exists store_root then ()
      else
        let _ =
          Process.run ~prog:"nix-store" ~args:[ "--realise"; store_root ] ()
        in
        ()

let split_target target =
  match String.index_opt target '#' with
  | None -> None
  | Some hash_index ->
      let flake_ref = String.sub target 0 hash_index in
      let config_name =
        String.sub target (hash_index + 1)
          (String.length target - hash_index - 1)
      in
      if flake_ref = "" || config_name = "" then None
      else Some (flake_ref, config_name)

let canonicalize_target target =
  match split_target target with
  | None -> target
  | Some (flake_ref, config_name) ->
      if String.starts_with ~prefix:"nixosConfigurations." config_name then
        target
      else flake_ref ^ "#nixosConfigurations." ^ config_name

let check_target_exists target =
  let result =
    Process.run ~prog:"nix"
      ~args:[ "eval"; target; "--apply"; "x: true" ]
      ()
  in
  if result.status <> 0 then
    Error
      {
        target;
        details = Printf.sprintf "target '%s' not found in flake" target;
        exit_code = Some result.status;
      }
  else Ok ()

let resolve_descriptor target =
  let target = expand_flake_ref_tilde target in
  let target = canonicalize_target target in
  match Sys.getenv_opt "EPI_TARGET_RESOLVER_CMD" with
  | Some resolver_cmd ->
      let env = Process.env_with [ ("EPI_TARGET", target) ] in
      let process_result =
        Process.run ~env ~prog:"/bin/sh" ~args:[ "-c"; resolver_cmd ] ()
      in
      if process_result.status <> 0 then
        Error
          {
            target;
            details =
              (if process_result.stderr = "" then "<no stderr>"
               else process_result.stderr);
            exit_code = Some process_result.status;
          }
      else (
        match Yojson.Basic.from_string process_result.stdout with
        | json -> Ok (descriptor_of_json json)
        | exception Yojson.Json_error msg ->
            Error { target; details = "invalid JSON output: " ^ msg; exit_code = None })
  | None -> (
      match check_target_exists target with
      | Error _ as e -> e
      | Ok () ->
          let process_result =
            Process.run ~prog:"nix"
              ~args:[ "eval"; "--json"; target ^ ".config.epi" ]
              ()
          in
          if process_result.status <> 0 then
            Error
              {
                target;
                details =
                  (if process_result.stderr = "" then "<no stderr>"
                   else process_result.stderr);
                exit_code = Some process_result.status;
              }
          else (
            match Yojson.Basic.from_string process_result.stdout with
            | json -> Ok (descriptor_of_json json)
            | exception Yojson.Json_error msg ->
                Error { target; details = "invalid JSON output: " ^ msg; exit_code = None }))

let build_target_artifact_if_missing ~target ~label =
  match split_target target with
  | None -> ()
  | Some (flake_ref, config_name) ->
      let build_target =
        match label with
        | "kernel" ->
            flake_ref ^ "#" ^ config_name ^ ".config.system.build.kernel"
        | "disk" ->
            flake_ref ^ "#" ^ config_name ^ ".config.system.build.image"
        | "initrd" ->
            flake_ref ^ "#" ^ config_name
            ^ ".config.system.build.initialRamdisk"
        | _ -> ""
      in
      if build_target <> "" then
        let _ = Process.run ~prog:"nix" ~args:[ "build"; build_target ] () in
        ()

let validate_file ~target ~label path =
  if path = "" then Error ("missing launch input: " ^ label)
  else (
    if not (Sys.file_exists path) then (
      Printf.printf "vm: building %s\n%!" label;
      ensure_store_realized path);
    if not (Sys.file_exists path) then
      build_target_artifact_if_missing ~target ~label;
    if not (Sys.file_exists path) then ensure_store_realized path;
    if not (Sys.file_exists path) then
      Error ("missing launch input: " ^ label ^ " (" ^ path ^ ")")
    else Ok ())

let is_nix_store_path path = String.starts_with ~prefix:"/nix/store/" path

let descriptor_paths descriptor =
  let base_paths = [ descriptor.kernel; descriptor.disk ] in
  match descriptor.initrd with
  | Some initrd_path -> initrd_path :: base_paths
  | None -> base_paths

let all_paths_share_parent descriptor =
  match descriptor_paths descriptor with
  | [] -> true
  | first_path :: rest ->
      let first_parent = Filename.dirname first_path in
      List.for_all
        (fun path -> String.equal (Filename.dirname path) first_parent)
        rest

let validate_descriptor_coherence descriptor =
  let kernel_is_store = is_nix_store_path descriptor.kernel in
  let disk_is_store = is_nix_store_path descriptor.disk in
  let initrd_is_store =
    match descriptor.initrd with
    | Some initrd_path -> is_nix_store_path initrd_path
    | None -> true
  in
  let any_store_path =
    kernel_is_store || disk_is_store
    || match descriptor.initrd with Some _ -> initrd_is_store | None -> false
  in
  if
    any_store_path
    && ((not kernel_is_store) || (not disk_is_store) || not initrd_is_store)
  then
    Error
      "launch inputs are not coherent: kernel/initrd/disk must all come from \
       target outputs in /nix/store; fix target outputs and rebuild instead of \
       reusing an external mutable disk image"
  else if (not any_store_path) && not (all_paths_share_parent descriptor) then
    Error
      "launch inputs are not coherent: kernel/initrd/disk must come from the \
       same target-built output set; fix target outputs and rebuild instead of \
       reusing an external mutable disk image"
  else Ok ()

let validate_descriptor ~target descriptor =
  let ( let* ) = Result.bind in
  let* () = validate_file ~target ~label:"kernel" descriptor.kernel in
  let* () = validate_file ~target ~label:"disk" descriptor.disk in
  let* () = match descriptor.initrd with
    | Some initrd_path -> validate_file ~target ~label:"initrd" initrd_path
    | None -> Ok ()
  in
  if descriptor.cpus <= 0 then Error "missing launch input: cpus must be > 0"
  else if descriptor.memory_mib <= 0 then Error "missing launch input: memory_mib must be > 0"
  else validate_descriptor_coherence descriptor

let cache_dir () =
  let dir =
    match Sys.getenv_opt "EPI_CACHE_DIR" with
    | Some dir -> dir
    | None -> (
        match Sys.getenv_opt "HOME" with
        | Some home -> Filename.concat home ".cache/epi"
        | None -> ".epi/cache")
  in
  let dir =
    if Filename.is_relative dir then Filename.concat (Sys.getcwd ()) dir
    else dir
  in
  if not (Sys.file_exists dir) then Unix.mkdir dir 0o755;
  dir

let cache_path target =
  let hash = Digest.string target |> Digest.to_hex in
  let target_cache = Filename.concat (cache_dir ()) "targets" in
  if not (Sys.file_exists target_cache) then Unix.mkdir target_cache 0o755;
  Filename.concat target_cache (hash ^ ".descriptor")

let descriptor_to_json descriptor =
  let hooks_fields =
    (match descriptor.hooks.post_launch with
     | [] -> []
     | paths -> [("post-launch", `List (List.map (fun s -> `String s) paths))])
    @
    (match descriptor.hooks.pre_stop with
     | [] -> []
     | paths -> [("pre-stop", `List (List.map (fun s -> `String s) paths))])
  in
  `Assoc ([
    ("kernel", `String descriptor.kernel);
    ("disk", `String descriptor.disk);
    ("initrd", match descriptor.initrd with Some s -> `String s | None -> `Null);
    ("cmdline", `String descriptor.cmdline);
    ("cpus", `Int descriptor.cpus);
    ("memory_mib", `Int descriptor.memory_mib);
    ("configuredUsers", `List (List.map (fun s -> `String s) descriptor.configured_users));
  ] @ (match hooks_fields with [] -> [] | _ -> [("hooks", `Assoc hooks_fields)]))

let save_descriptor_cache target descriptor =
  let path = cache_path target in
  Util.ensure_parent_dir path;
  Yojson.Basic.to_file path (descriptor_to_json descriptor)

let load_descriptor_cache target =
  let path = cache_path target in
  match Yojson.Basic.from_file path with
  | json -> Some (descriptor_of_json json)
  | exception _ -> None

let descriptor_paths_exist descriptor =
  List.for_all Sys.file_exists (descriptor_paths descriptor)

type cache_result = Cached of descriptor | Resolved of descriptor

let resolve_descriptor_cached ~rebuild target =
  let path = cache_path target in
  if rebuild && Sys.file_exists path then Sys.remove path;
  match load_descriptor_cache target with
  | Some descriptor when descriptor_paths_exist descriptor ->
      Ok (Cached descriptor)
  | _ -> (
      match resolve_descriptor target with
      | Error _ as error -> error
      | Ok descriptor ->
          save_descriptor_cache target descriptor;
          Ok (Resolved descriptor))
