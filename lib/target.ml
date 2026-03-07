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

type descriptor = {
  kernel : string;
  disk : string;
  initrd : string option;
  cmdline : string;
  cpus : int;
  memory_mib : int;
  configured_users : string list;
}

let default_cmdline = "console=ttyS0 root=/dev/vda2 ro"

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

let lowercase text = String.lowercase_ascii text

let read_file_if_exists path =
  if not (Sys.file_exists path) then ""
  else
    let channel = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in channel)
      (fun () ->
        let buffer = Buffer.create 128 in
        let rec loop () =
          match input_line channel with
          | line ->
              Buffer.add_string buffer line;
              Buffer.add_char buffer '\n';
              loop ()
          | exception End_of_file -> Buffer.contents buffer
        in
        loop ())

let parse_key_value_output text =
  let add_pair acc line =
    match String.split_on_char '=' line with
    | key :: value_parts when key <> "" ->
        let value = String.concat "=" value_parts |> String.trim in
        if value = "" then acc else (String.trim key, value) :: acc
    | _ -> acc
  in
  text |> String.split_on_char '\n' |> List.fold_left add_pair [] |> List.rev

let find_json_string ~key text =
  let marker = "\"" ^ key ^ "\"" in
  match String.index_from_opt text 0 '"' with
  | None -> None
  | Some _ -> (
      match String.index_opt text ':' with
      | None -> None
      | Some _ -> (
          let marker_len = String.length marker in
          let rec find_marker start =
            if start + marker_len > String.length text then None
            else if String.sub text start marker_len = marker then
              Some (start + marker_len)
            else find_marker (start + 1)
          in
          match find_marker 0 with
          | None -> None
          | Some after_marker -> (
              let rec find_quote i =
                if i >= String.length text then None
                else if text.[i] = '"' then Some i
                else find_quote (i + 1)
              in
              match find_quote after_marker with
              | None -> None
              | Some start_quote -> (
                  let rec find_end i =
                    if i >= String.length text then None
                    else if text.[i] = '"' && text.[i - 1] <> '\\' then Some i
                    else find_end (i + 1)
                  in
                  match find_end (start_quote + 1) with
                  | None -> None
                  | Some end_quote ->
                      Some
                        (String.sub text (start_quote + 1)
                           (end_quote - start_quote - 1))))))

let find_json_int ~key text =
  let marker = "\"" ^ key ^ "\"" in
  let marker_len = String.length marker in
  let rec find_marker start =
    if start + marker_len > String.length text then None
    else if String.sub text start marker_len = marker then
      Some (start + marker_len)
    else find_marker (start + 1)
  in
  match find_marker 0 with
  | None -> None
  | Some after_marker -> (
      let rec find_digit i =
        if i >= String.length text then None
        else
          let c = text.[i] in
          if c >= '0' && c <= '9' then Some i else find_digit (i + 1)
      in
      match find_digit after_marker with
      | None -> None
      | Some digit_start ->
          let rec find_end i =
            if i >= String.length text then i
            else
              let c = text.[i] in
              if c >= '0' && c <= '9' then find_end (i + 1) else i
          in
          let digit_end = find_end digit_start in
          int_of_string_opt
            (String.sub text digit_start (digit_end - digit_start)))

let parse_json_string_array text =
  let len = String.length text in
  let rec find_open i =
    if i >= len then i
    else if text.[i] = '[' then i + 1
    else find_open (i + 1)
  in
  let start = find_open 0 in
  let rec collect acc i =
    if i >= len then List.rev acc
    else if text.[i] = ']' then List.rev acc
    else if text.[i] = '"' then
      let rec find_end j =
        if j >= len then j
        else if text.[j] = '"' && text.[j - 1] <> '\\' then j
        else find_end (j + 1)
      in
      let end_quote = find_end (i + 1) in
      let s = String.sub text (i + 1) (end_quote - i - 1) in
      collect (s :: acc) (end_quote + 1)
    else collect acc (i + 1)
  in
  collect [] start

let descriptor_of_output raw_output =
  let first_some a b = match a with Some _ -> a | None -> b in
  let kv_pairs = parse_key_value_output raw_output in
  let kv key = List.assoc_opt key kv_pairs in
  let json key = find_json_string ~key raw_output in
  let json_int key = find_json_int ~key raw_output in
  let kernel =
    first_some (kv "kernel") (json "kernel") |> Option.value ~default:""
  in
  let disk = first_some (kv "disk") (json "disk") |> Option.value ~default:"" in
  let initrd = first_some (kv "initrd") (json "initrd") in
  let cmdline =
    first_some (kv "cmdline") (json "cmdline")
    |> Option.value ~default:default_cmdline
  in
  let cpus =
    match
      first_some (Option.bind (kv "cpus") int_of_string_opt) (json_int "cpus")
    with
    | Some value -> value
    | None -> 1
  in
  let memory_mib =
    match
      first_some
        (Option.bind (kv "memory_mib") int_of_string_opt)
        (json_int "memory_mib")
    with
    | Some value -> value
    | None -> 1024
  in
  let configured_users =
    match kv "configured_users" with
    | Some csv when csv <> "" ->
        String.split_on_char ',' csv
        |> List.map String.trim
        |> List.filter (fun s -> s <> "")
    | _ ->
        let marker = "\"configuredUsers\"" in
        let marker_len = String.length marker in
        let raw_len = String.length raw_output in
        let rec find_marker i =
          if i + marker_len > raw_len then None
          else if String.sub raw_output i marker_len = marker then
            let rec find_bracket j =
              if j >= raw_len then None
              else if raw_output.[j] = '[' then
                let rec find_close k =
                  if k >= raw_len then None
                  else if raw_output.[k] = ']' then
                    Some (String.sub raw_output j (k - j + 1))
                  else find_close (k + 1)
                in
                find_close j
              else find_bracket (j + 1)
            in
            find_bracket (i + marker_len)
          else find_marker (i + 1)
        in
        (match find_marker 0 with
         | Some array_text -> parse_json_string_array array_text
         | None -> [])
  in
  { kernel; disk; initrd; cmdline; cpus; memory_mib; configured_users }

type resolution_error = {
  target : string;
  details : string;
  exit_code : int option;
}

let resolve_descriptor target =
  let process_result =
    match Sys.getenv_opt "EPI_TARGET_RESOLVER_CMD" with
    | Some resolver_cmd ->
        let env = Process.env_with [ ("EPI_TARGET", target) ] in
        Process.run ~env ~prog:"/bin/sh" ~args:[ "-c"; resolver_cmd ] ()
    | None ->
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
  else Ok (descriptor_of_output process_result.stdout)

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

let build_target_artifact_if_missing ~target ~label =
  match split_target target with
  | None -> ()
  | Some (flake_ref, config_name) ->
      let build_target =
        match label with
        | "kernel" ->
            flake_ref ^ "#" ^ config_name ^ ".config.system.build.kernel"
        | "disk" ->
            flake_ref ^ "#" ^ config_name ^ ".config.system.build.images.qemu"
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
      Printf.printf "up: building %s\n%!" label;
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
  match validate_file ~target ~label:"kernel" descriptor.kernel with
  | Error _ as error -> error
  | Ok () -> (
      match validate_file ~target ~label:"disk" descriptor.disk with
      | Error _ as error -> error
      | Ok () -> (
          match descriptor.initrd with
          | Some initrd_path -> (
              match validate_file ~target ~label:"initrd" initrd_path with
              | Error _ as error -> error
              | Ok () ->
                  if descriptor.cpus <= 0 then
                    Error "missing launch input: cpus must be > 0"
                  else if descriptor.memory_mib <= 0 then
                    Error "missing launch input: memory_mib must be > 0"
                  else validate_descriptor_coherence descriptor)
          | None ->
              if descriptor.cpus <= 0 then
                Error "missing launch input: cpus must be > 0"
              else if descriptor.memory_mib <= 0 then
                Error "missing launch input: memory_mib must be > 0"
              else validate_descriptor_coherence descriptor))

let cache_dir () =
  let dir =
    match Sys.getenv_opt "EPI_CACHE_DIR" with
    | Some dir -> dir
    | None -> (
        match Sys.getenv_opt "HOME" with
        | Some home -> Filename.concat home ".local/cache/epi"
        | None -> ".epi/cache")
  in
  if not (Sys.file_exists dir) then Unix.mkdir dir 0o755;
  dir

let cache_path target =
  let hash = Digest.string target |> Digest.to_hex in
  let target_cache = Filename.concat (cache_dir ()) "targets" in
  if not (Sys.file_exists target_cache) then Unix.mkdir target_cache 0o755;
  Filename.concat target_cache (hash ^ ".descriptor")

let save_descriptor_cache target descriptor =
  let path = cache_path target in
  Process.ensure_parent_dir path;
  let channel = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out channel)
    (fun () ->
      Printf.fprintf channel "kernel=%s\n" descriptor.kernel;
      Printf.fprintf channel "disk=%s\n" descriptor.disk;
      (match descriptor.initrd with
      | Some initrd -> Printf.fprintf channel "initrd=%s\n" initrd
      | None -> ());
      Printf.fprintf channel "cmdline=%s\n" descriptor.cmdline;
      Printf.fprintf channel "cpus=%d\n" descriptor.cpus;
      Printf.fprintf channel "memory_mib=%d\n" descriptor.memory_mib;
      (match descriptor.configured_users with
      | [] -> ()
      | users ->
          Printf.fprintf channel "configured_users=%s\n"
            (String.concat "," users)))

let load_descriptor_cache target =
  let path = cache_path target in
  if not (Sys.file_exists path) then None
  else
    let content = read_file_if_exists path in
    if content = "" then None else Some (descriptor_of_output content)

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
