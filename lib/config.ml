type t = {
  target : string option;
  mounts : string list option;
  disk_size : string option;
}

let empty = { target = None; mounts = None; disk_size = None }
let config_path = Filename.concat ".epi" "config.toml"

let getenv_nonempty name =
  match Sys.getenv_opt name with Some "" | None -> None | Some v -> Some v

let user_config_path () =
  match getenv_nonempty "EPI_CONFIG_FILE" with
  | Some path -> Some path
  | None ->
      let dir =
        match getenv_nonempty "XDG_CONFIG_HOME" with
        | Some xdg -> xdg
        | None -> Filename.concat (Sys.getenv "HOME") ".config"
      in
      Some (Filename.concat (Filename.concat dir "epi") "config.toml")

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

let resolve_mounts ~base paths = List.map (resolve_path ~base) paths

let parse_config ~path ~base content =
  match Otoml.Parser.from_string_result content with
  | Error msg -> Error (Printf.sprintf "%s: %s" path msg)
  | Ok toml ->
      let target = Otoml.Helpers.find_string_opt toml [ "target" ] in
      let mounts =
        match Otoml.Helpers.find_strings_opt toml [ "mounts" ] with
        | Some paths -> Some (resolve_mounts ~base paths)
        | None -> None
      in
      let disk_size = Otoml.Helpers.find_string_opt toml [ "disk_size" ] in
      Ok { target; mounts; disk_size }

let load () =
  if not (Sys.file_exists config_path) then Ok empty
  else
    match Util.read_file config_path with
    | None -> Ok empty
    | Some content ->
        parse_config ~path:config_path ~base:(Sys.getcwd ()) content

let load_user () =
  match user_config_path () with
  | None -> Ok empty
  | Some path -> (
      let explicit = getenv_nonempty "EPI_CONFIG_FILE" <> None in
      if not (Sys.file_exists path) then
        if explicit then Error (Printf.sprintf "Config file not found: %s" path)
        else Ok empty
      else
        match Util.read_file path with
        | None -> Ok empty
        | Some content ->
            parse_config ~path ~base:(Filename.dirname path) content)

type resolved = {
  resolved_target : string;
  resolved_mounts : string list;
  resolved_disk_size : string;
}

let merge_configs ~user ~project =
  {
    target =
      (match project.target with
      | Some _ -> project.target
      | None -> user.target);
    mounts =
      (match project.mounts with
      | Some _ -> project.mounts
      | None -> user.mounts);
    disk_size =
      (match project.disk_size with
      | Some _ -> project.disk_size
      | None -> user.disk_size);
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
    | None -> ( match config.disk_size with Some s -> s | None -> "40G")
  in
  Ok
    {
      resolved_target = target;
      resolved_mounts = mounts;
      resolved_disk_size = disk_size;
    }
