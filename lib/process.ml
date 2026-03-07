type result = { status : int; stdout : string; stderr : string }
type detached_result = { pid : int }

let read_all channel =
  let buffer = Buffer.create 256 in
  let rec loop () =
    match input_line channel with
    | line ->
        Buffer.add_string buffer line;
        Buffer.add_char buffer '\n';
        loop ()
    | exception End_of_file -> Buffer.contents buffer
  in
  loop ()

let run ?(env = Unix.environment ()) ~prog ~args () =
  let argv = Array.of_list (prog :: args) in
  let stdout_channel, stdin_channel, stderr_channel =
    Unix.open_process_args_full prog argv env
  in
  close_out stdin_channel;
  let stdout = read_all stdout_channel |> String.trim in
  let stderr = read_all stderr_channel |> String.trim in
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

let run_detached ?(env = Unix.environment ()) ~prog ~args ~stdout_path
    ~stderr_path () =
  ensure_parent_dir stdout_path;
  ensure_parent_dir stderr_path;
  let argv = Array.of_list (prog :: args) in
  let stdin_fd = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
  let stdout_fd =
    Unix.openfile stdout_path
      [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ]
      0o644
  in
  let stderr_fd =
    Unix.openfile stderr_path
      [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ]
      0o644
  in
  let pid = Unix.fork () in
  if pid = 0 then (
    ignore (Unix.setsid ());
    Unix.dup2 stdin_fd Unix.stdin;
    Unix.dup2 stdout_fd Unix.stdout;
    Unix.dup2 stderr_fd Unix.stderr;
    Unix.close stdin_fd;
    Unix.close stdout_fd;
    Unix.close stderr_fd;
    (try Unix.execvpe prog argv env with _ -> exit 127))
  else (
    Unix.close stdin_fd;
    Unix.close stdout_fd;
    Unix.close stderr_fd;
    { pid })

let pid_is_alive pid =
  try
    Unix.kill pid 0;
    true
  with
  | Unix.Unix_error (Unix.ESRCH, _, _) -> false
  | Unix.Unix_error (Unix.EPERM, _, _) -> true
