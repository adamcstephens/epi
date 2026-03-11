let user_hooks_dir () =
  let dir =
    match Sys.getenv_opt "XDG_CONFIG_HOME" with
    | Some xdg -> xdg
    | None -> Filename.concat (Sys.getenv "HOME") ".config"
  in
  Filename.concat (Filename.concat dir "epi") "hooks"

let project_hooks_dir () = Filename.concat ".epi" "hooks"

let discover_scripts dir =
  if not (Sys.file_exists dir && Sys.is_directory dir) then []
  else
    Sys.readdir dir
    |> Array.to_list
    |> List.filter (fun name ->
        name.[0] <> '.'
        && not (Sys.is_directory (Filename.concat dir name)))
    |> List.sort String.compare
    |> List.filter_map (fun name ->
        let path = Filename.concat dir name in
        let st = Unix.stat path in
        if st.Unix.st_perm land 0o111 <> 0 then Some path
        else (
          Printf.eprintf "warning: skipping non-executable hook: %s\n%!" path;
          None))

let discover_from_dir ~instance_name dir =
  let top = discover_scripts dir in
  let instance_dir = Filename.concat dir instance_name in
  let instance = discover_scripts instance_dir in
  top @ instance

let discover ~instance_name hook_point =
  let user_dir = Filename.concat (user_hooks_dir ()) (hook_point ^ ".d") in
  let project_dir = Filename.concat (project_hooks_dir ()) (hook_point ^ ".d") in
  discover_from_dir ~instance_name user_dir
  @ discover_from_dir ~instance_name project_dir

let discover_guest ~instance_name =
  discover ~instance_name "guest-init"

type hook_env = {
  instance_name : string;
  ssh_port : int;
  ssh_key_path : string;
  ssh_user : string;
  state_dir : string;
}

let execute ~env scripts =
  match scripts with
  | [] -> Ok ()
  | _ ->
      let process_env =
        Process.env_with [
          ("EPI_INSTANCE", env.instance_name);
          ("EPI_SSH_PORT", string_of_int env.ssh_port);
          ("EPI_SSH_KEY", env.ssh_key_path);
          ("EPI_SSH_USER", env.ssh_user);
          ("EPI_STATE_DIR", env.state_dir);
        ]
      in
      let rec run_all = function
        | [] -> Ok ()
        | script :: rest ->
            let result =
              Process.run ~env:process_env ~prog:script ~args:[] ()
            in
            if result.status <> 0 then
              Error (Printf.sprintf "hook %s failed with exit code %d: %s"
                       script result.status
                       (if result.stderr = "" then "<no stderr>" else result.stderr))
            else run_all rest
      in
      run_all scripts
