type t = {
  target : string option;
  mounts : string list option;
  disk_size : string option;
}

let empty = { target = None; mounts = None; disk_size = None }

let config_path = Filename.concat ".epi" "config.toml"

let expand_tilde path =
  if path = "~" then Sys.getenv "HOME"
  else if String.starts_with ~prefix:"~/" path then
    let home = Sys.getenv "HOME" in
    Filename.concat home (String.sub path 2 (String.length path - 2))
  else path

let strip_dot_slash path =
  if String.starts_with ~prefix:"./" path then
    String.sub path 2 (String.length path - 2)
  else path

let resolve_path ~base path =
  let expanded = expand_tilde path in
  if Filename.is_relative expanded then
    Filename.concat base (strip_dot_slash expanded)
  else expanded

let resolve_mounts ~base paths =
  List.map (resolve_path ~base) paths

let load () =
  if not (Sys.file_exists config_path) then Ok empty
  else
    match Util.read_file config_path with
    | None -> Ok empty
    | Some content -> (
        match Otoml.Parser.from_string_result content with
        | Error msg ->
            Error (Printf.sprintf "%s: %s" config_path msg)
        | Ok toml ->
            let project_root = Sys.getcwd () in
            let target = Otoml.Helpers.find_string_opt toml ["target"] in
            let mounts =
              match Otoml.Helpers.find_strings_opt toml ["mounts"] with
              | Some paths -> Some (resolve_mounts ~base:project_root paths)
              | None -> None
            in
            let disk_size = Otoml.Helpers.find_string_opt toml ["disk_size"] in
            Ok { target; mounts; disk_size })

type resolved = {
  resolved_target : string;
  resolved_mounts : string list;
  resolved_disk_size : string;
}

let merge ~cli_target ~cli_mounts ~cli_disk_size config =
  let ( let* ) = Result.bind in
  let* target =
    match cli_target with
    | Some t -> Ok t
    | None -> (
        match config.target with
        | Some t -> Ok t
        | None ->
            Error
              "No target specified. Provide --target <flake-ref>#<config-name> \
               or set target in .epi/config.toml")
  in
  let mounts =
    if cli_mounts <> [] then cli_mounts
    else match config.mounts with Some m -> m | None -> []
  in
  let disk_size =
    match cli_disk_size with
    | Some s -> s
    | None -> (match config.disk_size with Some s -> s | None -> "40G")
  in
  Ok { resolved_target = target; resolved_mounts = mounts; resolved_disk_size = disk_size }
