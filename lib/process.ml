type result = { status : int; stdout : string; stderr : string }

let run ?(env = Unix.environment ()) ~prog ~args () =
  let argv = Array.of_list (prog :: args) in
  let stdout_channel, stdin_channel, stderr_channel =
    Unix.open_process_args_full prog argv env
  in
  close_out stdin_channel;
  let stdout = In_channel.input_all stdout_channel |> String.trim in
  let stderr = In_channel.input_all stderr_channel |> String.trim in
  let status =
    match
      Unix.close_process_full (stdout_channel, stdin_channel, stderr_channel)
    with
    | Unix.WEXITED code -> code
    | Unix.WSIGNALED signal -> 128 + signal
    | Unix.WSTOPPED signal -> 128 + signal
  in
  { status; stdout; stderr }

let env_with additions =
  Array.append (Unix.environment ())
    (Array.of_list (List.map (fun (key, value) -> key ^ "=" ^ value) additions))

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

let escape_unit_name name =
  let result = run ~prog:"systemd-escape" ~args:[ name ] () in
  if result.status = 0 then result.stdout
  else failwith (Printf.sprintf "systemd-escape failed for %S: %s" name result.stderr)

let generate_unit_id () =
  let buf = Buffer.create 16 in
  let ic = open_in "/dev/urandom" in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () ->
      for _ = 1 to 4 do
        let byte = input_byte ic in
        Buffer.add_string buf (Printf.sprintf "%02x" byte)
      done);
  Buffer.contents buf

let systemctl_bin = "/run/current-system/sw/bin/systemctl"

let setenv_args () =
  Unix.environment ()
  |> Array.to_list
  |> List.filter_map (fun entry ->
      match String.index_opt entry '=' with
      | Some _ -> Some ("--setenv=" ^ entry)
      | None -> None)

let run_helper ~unit_name ~slice ~prog ~args () =
  run ~prog:"systemd-run"
    ~args:
      ([ "--user"; "--collect";
         "--unit=" ^ unit_name;
         "--slice=" ^ slice ]
       @ setenv_args ()
       @ [ "--" ]
       @ (prog :: args))
    ()

let run_service ~unit_name ~slice ~exec_stop_post ~prog ~args () =
  run ~prog:"systemd-run"
    ~args:
      ([ "--user"; "--collect";
         "--unit=" ^ unit_name;
         "--slice=" ^ slice;
         "--property=Type=exec";
         "--property=ExecStopPost=" ^ exec_stop_post ]
       @ setenv_args ()
       @ [ "--" ]
       @ (prog :: args))
    ()


let unit_is_active unit_name =
  let result = run ~prog:systemctl_bin ~args:[ "--user"; "is-active"; unit_name ] () in
  result.status = 0

let stop_unit unit_name =
  let result = run ~prog:systemctl_bin ~args:[ "--user"; "stop"; unit_name ] () in
  result.status = 0
