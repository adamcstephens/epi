let default_instance_name = "default"

type runtime = {
  pid : int;
  serial_socket : string;
  disk : string;
  passt_pid : int option;
}

type entry = {
  instance_name : string;
  target : string;
  runtime : runtime option;
}

let state_file () =
  match Sys.getenv_opt "EPI_STATE_FILE" with
  | Some path -> path
  | None -> (
      match Sys.getenv_opt "HOME" with
      | Some home -> Filename.concat home ".local/state/epi/instances.tsv"
      | None -> ".epi-instances.tsv")

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

let state_dir () = Filename.dirname (state_file ())
let runtime_dir () = Filename.concat (state_dir ()) "runtime"

let serial_socket_path instance_name =
  Filename.concat (runtime_dir ()) (instance_name ^ ".serial.sock")

let launch_stdout_path instance_name =
  Filename.concat (runtime_dir ()) (instance_name ^ ".stdout.log")

let launch_stderr_path instance_name =
  Filename.concat (runtime_dir ()) (instance_name ^ ".stderr.log")

let parse_int text = int_of_string_opt text

let runtime_of_fields pid_text serial_socket disk passt_pid =
  match parse_int pid_text with
  | Some pid when pid > 0 -> Some { pid; serial_socket; disk; passt_pid }
  | _ -> None

let entry_of_fields = function
  | [ instance_name; target ] -> Some { instance_name; target; runtime = None }
  | [ instance_name; target; pid_text ] ->
      Some
        {
          instance_name;
          target;
          runtime = runtime_of_fields pid_text "" "" None;
        }
  | [ instance_name; target; pid_text; serial_socket; disk ] ->
      Some
        {
          instance_name;
          target;
          runtime = runtime_of_fields pid_text serial_socket disk None;
        }
  | [ instance_name; target; pid_text; serial_socket; disk; passt_pid_text ] ->
      Some
        {
          instance_name;
          target;
          runtime =
            runtime_of_fields pid_text serial_socket disk
              (parse_int passt_pid_text);
        }
  | _ -> None

let load () =
  let path = state_file () in
  if not (Sys.file_exists path) then []
  else
    let channel = open_in path in
    let rec loop acc =
      match input_line channel with
      | line -> (
          match entry_of_fields (String.split_on_char '\t' line) with
          | Some entry -> loop (entry :: acc)
          | None -> loop acc)
      | exception End_of_file ->
          close_in channel;
          List.rev acc
    in
    loop []

let save entries =
  let path = state_file () in
  ensure_parent_dir path;
  let channel = open_out path in
  List.iter
    (fun { instance_name; target; runtime } ->
      match runtime with
      | Some { pid; serial_socket; disk; passt_pid } ->
          let passt_pid_text =
            match passt_pid with Some p -> string_of_int p | None -> ""
          in
          Printf.fprintf channel "%s\t%s\t%d\t%s\t%s\t%s\n" instance_name
            target pid serial_socket disk passt_pid_text
      | None -> Printf.fprintf channel "%s\t%s\t\t\t\t\n" instance_name target)
    entries;
  close_out channel

let upsert_entry ~instance_name ~update entries =
  let rec upsert acc = function
    | [] ->
        List.rev (update { instance_name; target = ""; runtime = None } :: acc)
    | ({ instance_name = name; _ } as entry) :: rest
      when String.equal name instance_name ->
        List.rev_append acc (update entry :: rest)
    | entry :: rest -> upsert (entry :: acc) rest
  in
  upsert [] entries

let set ~instance_name ~target =
  let update entry = { entry with target; runtime = None } in
  save (upsert_entry ~instance_name ~update (load ()))

let set_provisioned ~instance_name ~target ~runtime =
  let update entry = { entry with target; runtime = Some runtime } in
  save (upsert_entry ~instance_name ~update (load ()))

let find_entry instance_name =
  List.find_opt
    (fun entry -> String.equal entry.instance_name instance_name)
    (load ())

let find instance_name =
  match find_entry instance_name with
  | Some { target; _ } -> Some target
  | None -> None

let find_runtime instance_name =
  match find_entry instance_name with
  | Some { runtime; _ } -> runtime
  | None -> None

let list () =
  load ()
  |> List.map (fun { instance_name; target; _ } -> (instance_name, target))
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)

let clear_runtime instance_name =
  let entries = load () in
  if
    List.exists
      (fun entry -> String.equal entry.instance_name instance_name)
      entries
  then
    let update entry = { entry with runtime = None } in
    save (upsert_entry ~instance_name ~update entries)

let remove instance_name =
  let before = load () in
  let after =
    List.filter
      (fun entry -> not (String.equal entry.instance_name instance_name))
      before
  in
  if List.length before <> List.length after then save after

let find_running_owner_by_disk disk =
  load ()
  |> List.find_map (fun { instance_name; runtime; _ } ->
      match runtime with
      | Some ({ pid; disk = runtime_disk; _ } as instance_runtime)
        when String.equal runtime_disk disk && Process.pid_is_alive pid ->
          Some (instance_name, instance_runtime)
      | _ -> None)

let kill_if_alive pid =
  try Unix.kill pid Sys.sigterm
  with Unix.Unix_error (Unix.ESRCH, _, _) -> ()

let reconcile_runtime () =
  let clear_if_stale entry =
    match entry.runtime with
    | Some { pid; serial_socket; passt_pid; _ }
      when not (Process.pid_is_alive pid) ->
        (match passt_pid with
        | Some passt_pid -> kill_if_alive passt_pid
        | None -> ());
        if Sys.file_exists serial_socket then Unix.unlink serial_socket;
        { entry with runtime = None }
    | _ -> entry
  in
  let before = load () in
  let after = List.map clear_if_stale before in
  if before <> after then save after
