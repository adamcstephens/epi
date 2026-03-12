type output = { status : int; stdout : string; stderr : string }

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

let escape_unit_name name =
  let result = run ~prog:"systemd-escape" ~args:[ name ] () in
  if result.status = 0 then Ok result.stdout
  else
    Error (Printf.sprintf "systemd-escape failed for %S: %s" name result.stderr)

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

let systemd_run_bin () =
  match Sys.getenv_opt "EPI_SYSTEMD_RUN_BIN" with
  | Some bin -> bin
  | None -> "systemd-run"

let systemctl_bin () =
  match Sys.getenv_opt "EPI_SYSTEMCTL_BIN" with
  | Some bin -> bin
  | None -> "/run/current-system/sw/bin/systemctl"

let setenv_args () =
  Unix.environment () |> Array.to_list
  |> List.filter_map (fun entry ->
      match String.index_opt entry '=' with
      | Some _ -> Some ("--setenv=" ^ entry)
      | None -> None)

let run_helper ~unit_name ~slice ~prog ~args () =
  run ~prog:(systemd_run_bin ())
    ~args:
      ([ "--user"; "--collect"; "--unit=" ^ unit_name; "--slice=" ^ slice ]
      @ setenv_args () @ [ "--" ] @ (prog :: args))
    ()

let run_service ~unit_name ~slice ~exec_stop_posts ~prog ~args () =
  let stop_props =
    List.map (fun cmd -> "--property=ExecStopPost=" ^ cmd) exec_stop_posts
  in
  run ~prog:(systemd_run_bin ())
    ~args:
      ([
         "--user";
         "--collect";
         "--unit=" ^ unit_name;
         "--slice=" ^ slice;
         "--property=Type=exec";
       ]
      @ stop_props @ setenv_args () @ [ "--" ] @ (prog :: args))
    ()

let unit_is_active unit_name =
  let result =
    run ~prog:(systemctl_bin ()) ~args:[ "--user"; "is-active"; unit_name ] ()
  in
  result.status = 0

let stop_unit unit_name =
  let result =
    run ~prog:(systemctl_bin ()) ~args:[ "--user"; "stop"; unit_name ] ()
  in
  result.status = 0
