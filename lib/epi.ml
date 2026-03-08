module Command = Cmdlang.Command

let fail message =
  prerr_endline message;
  exit 1

type console_attach_options = {
  read_stdin : bool;
  capture_path : string option;
  timeout_seconds : float option;
}

let parse_env_boolean text =
  let lowered = String.lowercase_ascii (String.trim text) in
  if lowered = "1" || lowered = "true" || lowered = "yes" || lowered = "on" then
    Some true
  else if
    lowered = "0" || lowered = "false" || lowered = "no" || lowered = "off"
  then Some false
  else None

let parse_env_positive_float ~name text =
  match float_of_string_opt (String.trim text) with
  | Some value when value > 0.0 -> value
  | _ ->
      fail
        (Printf.sprintf "Invalid %s=%S. Expected a positive number of seconds."
           name text)

let resolve_console_attach_options () =
  let stdin_fd = Unix.descr_of_in_channel stdin in
  let default_read_stdin = Unix.isatty stdin_fd in
  let read_stdin =
    match Sys.getenv_opt "EPI_CONSOLE_NON_INTERACTIVE" with
    | Some flag -> (
        match parse_env_boolean flag with
        | Some true -> false
        | Some false -> true
        | None ->
            fail
              (Printf.sprintf
                 "Invalid EPI_CONSOLE_NON_INTERACTIVE=%S. Use true/false." flag)
        )
    | None -> default_read_stdin
  in
  let capture_path = Sys.getenv_opt "EPI_CONSOLE_CAPTURE_FILE" in
  let timeout_seconds =
    match Sys.getenv_opt "EPI_CONSOLE_TIMEOUT_SECONDS" with
    | Some seconds ->
        Some
          (parse_env_positive_float ~name:"EPI_CONSOLE_TIMEOUT_SECONDS" seconds)
    | None -> None
  in
  { read_stdin; capture_path; timeout_seconds }

let kill_if_alive pid =
  try Unix.kill pid Sys.sigterm
  with Unix.Unix_error (Unix.ESRCH, _, _) -> ()

let resolve_instance_name instance_name_opt =
  match instance_name_opt with
  | Some instance_name -> instance_name
  | None -> Instance_store.default_instance_name

let resolve_instance_target ~command_name instance_name_opt =
  Instance_store.reconcile_runtime ();
  let instance_name = resolve_instance_name instance_name_opt in
  match Instance_store.find instance_name with
  | Some target -> (instance_name, target)
  | None when instance_name_opt = None ->
      fail
        (Printf.sprintf
           "Instance '%s' was not found. Run `epi up --target <flake#config>` \
            to create it, or pass an instance name (for example: `epi %s \
            <instance>`)."
           Instance_store.default_instance_name command_name)
  | None ->
      fail
        (Printf.sprintf
           "Instance '%s' was not found. Run `epi list` to see known \
            instances, or create it with `epi up %s --target <flake#config>`."
           instance_name instance_name)

let attach_console_for_running_instance ~instance_name ~options runtime =
  if not (Process.pid_is_alive runtime.Instance_store.pid) then (
    Instance_store.clear_runtime instance_name;
    fail
      (Console.pp_console_error
         (Console.Instance_not_running { instance_name })))
  else
    match
      Console.attach_console ~instance_name ~read_stdin:options.read_stdin
        ?capture_path:options.capture_path
        ?timeout_seconds:options.timeout_seconds runtime
    with
    | Ok () -> ()
    | Error error -> fail (Console.pp_console_error error)

let pid_is_zombie pid =
  let path = Printf.sprintf "/proc/%d/stat" pid in
  if not (Sys.file_exists path) then false
  else
    let channel = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in channel)
      (fun () ->
        let line = input_line channel in
        match String.rindex_opt line ')' with
        | Some index when index + 2 < String.length line ->
            line.[index + 2] = 'Z'
        | _ -> false)

let up_command =
  Command.make ~summary:"Create or start an instance from a flake target."
    ~readme:(fun () ->
      "Use an optional instance name plus --target <flake-ref>#<config-name>.\n\
       If no instance name is provided, the instance defaults to `default`.\n\n\
       Examples:\n\
      \  epi up --target .#dev\n\
      \  epi up dev-a --target github:org/repo#dev-a")
    (let open Command.Std in
     let+ instance_name =
       Arg.pos_opt ~pos:0 Param.string ~docv:"INSTANCE" ~doc:"Instance name."
     and+ target =
       Arg.named [ "target" ]
         (Param.validated_string (module Target))
         ~docv:"FLAKE#CONFIG"
         ~doc:
           "Flake target in <flake-ref>#<config-name> form, for example .#dev."
     and+ attach_console =
       Arg.flag [ "console" ]
         ~doc:
           "Attach to the instance serial console immediately after ensuring \
            runtime is active."
     and+ rebuild =
       Arg.flag [ "rebuild" ]
         ~doc:
           "Force re-evaluation and rebuild of the target, bypassing any \
            cached descriptor."
     and+ generate_ssh_key =
       Arg.flag [ "generate-ssh-key" ]
         ~doc:
           "Generate an ed25519 keypair for this instance and include it in \
            cloud-init authorized_keys."
     and+ mount_path =
       Arg.named_opt [ "mount" ] Param.string
         ~docv:"PATH"
         ~doc:
           "Mount a host directory into the guest at the same path using \
            virtiofsd. Pass a path or use $(pwd) for the current directory."
     and+ disk_size =
       Arg.named_opt [ "disk-size" ] Param.string
         ~docv:"SIZE"
         ~doc:
           "Target size of the writable disk overlay (e.g. 40G, 50G). Only \
            applies when a new overlay is created. Defaults to 40G."
     in
     let disk_size = Option.value disk_size ~default:"40G" in
     let console_options = resolve_console_attach_options () in
     Instance_store.reconcile_runtime ();
     let instance_name = resolve_instance_name instance_name in
     match Instance_store.find_runtime instance_name with
     | Some runtime when Process.pid_is_alive runtime.pid ->
         if attach_console then (
           Printf.printf
             "up: instance=%s target=%s already-running pid=%d, attaching \
              console\n%!"
             instance_name target runtime.pid;
           attach_console_for_running_instance ~instance_name
             ~options:console_options runtime)
         else
           Printf.printf
             "up: instance=%s target=%s already-running pid=%d serial=%s\n"
             instance_name target runtime.pid runtime.serial_socket
     | Some stale_runtime -> (
         (match stale_runtime.Instance_store.passt_pid with
         | Some passt_pid -> kill_if_alive passt_pid
         | None -> ());
         (match stale_runtime.Instance_store.virtiofsd_pid with
         | Some virtiofsd_pid -> kill_if_alive virtiofsd_pid
         | None -> ());
         Instance_store.clear_runtime instance_name;
         match Vm_launch.provision ~rebuild ~generate_ssh_key ~mount_path ~disk_size ~instance_name ~target with
         | Ok runtime ->
             Instance_store.set_provisioned ~instance_name ~target ~runtime;
             if attach_console then
               attach_console_for_running_instance ~instance_name
                 ~options:console_options runtime
             else (
               Printf.printf
                 "up: provisioned instance=%s target=%s pid=%d serial=%s\n"
                 instance_name target runtime.Instance_store.pid
                 runtime.serial_socket;
               match runtime.Instance_store.ssh_port with
               | Some port -> Printf.printf "SSH port: %d\n" port
               | None -> ())
         | Error error -> fail (Vm_launch.pp_provision_error error))
     | None -> (
         match Vm_launch.provision ~rebuild ~generate_ssh_key ~mount_path ~disk_size ~instance_name ~target with
         | Ok runtime ->
             Instance_store.set_provisioned ~instance_name ~target ~runtime;
             if attach_console then
               attach_console_for_running_instance ~instance_name
                 ~options:console_options runtime
             else (
               Printf.printf
                 "up: provisioned instance=%s target=%s pid=%d serial=%s\n"
                 instance_name target runtime.Instance_store.pid
                 runtime.serial_socket;
               match runtime.Instance_store.ssh_port with
               | Some port -> Printf.printf "SSH port: %d\n" port
               | None -> ())
         | Error error -> fail (Vm_launch.pp_provision_error error)))

let lifecycle_command ~name ~summary =
  Command.make ~summary
    ~readme:(fun () ->
      Printf.sprintf
        "Operate on an existing instance.\n\
         If INSTANCE is omitted, `%s` is used."
        Instance_store.default_instance_name)
    (let open Command.Std in
     let+ instance_name =
       Arg.pos_opt ~pos:0 Param.string ~docv:"INSTANCE" ~doc:"Instance name."
     in
     let instance_name, target =
       resolve_instance_target ~command_name:name instance_name
     in
     Printf.printf "%s: instance=%s target=%s\n" name instance_name target)

let ssh_command =
  Command.make ~summary:"Open SSH session to an instance."
    ~readme:(fun () ->
      "SSH into a running instance.\n\
       If INSTANCE is omitted, `default` is used.\n\n\
       Connects to 127.0.0.1 on the port allocated during `up`.\n\
       Host key checking is disabled since VMs generate fresh keys on each \
       provision.")
    (let open Command.Std in
     let+ instance_name_opt =
       Arg.pos_opt ~pos:0 Param.string ~docv:"INSTANCE" ~doc:"Instance name."
     in
     Instance_store.reconcile_runtime ();
     let instance_name = resolve_instance_name instance_name_opt in
     match Instance_store.find_runtime instance_name with
     | None ->
         fail
           (Printf.sprintf "Instance '%s' is not running. Start it with: epi up"
              instance_name)
     | Some runtime when not (Process.pid_is_alive runtime.pid) ->
         fail
           (Printf.sprintf "Instance '%s' is not running. Start it with: epi up"
              instance_name)
     | Some runtime -> (
         match runtime.Instance_store.ssh_port with
         | None ->
             fail
               (Printf.sprintf
                  "Instance '%s' has no SSH port. Try stopping and restarting it."
                  instance_name)
         | Some port ->
             let username =
               match Sys.getenv_opt "USER" with
               | Some u -> u
               | None -> "user"
             in
             let port_str = string_of_int port in
             let target = username ^ "@127.0.0.1" in
             let key_args =
               match runtime.Instance_store.ssh_key_path with
               | Some path -> [| "-i"; path |]
               | None -> [||]
             in
             let args =
               Array.concat
                 [
                   [| "ssh"; "-p"; port_str |];
                   key_args;
                   [|
                     "-o";
                     "StrictHostKeyChecking=no";
                     "-o";
                     "UserKnownHostsFile=/dev/null";
                     target;
                   |];
                 ]
             in
             Unix.execvp "ssh" args))

let console_command =
  Command.make ~summary:"Attach to an instance serial console."
    ~readme:(fun () ->
      "Attach to the serial console for a running instance.\n\
       If INSTANCE is omitted, `default` is used.")
    (let open Command.Std in
     let+ instance_name_opt =
       Arg.pos_opt ~pos:0 Param.string ~docv:"INSTANCE" ~doc:"Instance name."
     in
     Instance_store.reconcile_runtime ();
     let console_options = resolve_console_attach_options () in
     let instance_name = resolve_instance_name instance_name_opt in
     match Instance_store.find_runtime instance_name with
     | None ->
         fail
           (Console.pp_console_error
              (Console.Instance_not_running { instance_name }))
     | Some runtime ->
         attach_console_for_running_instance ~instance_name
           ~options:console_options runtime)

let terminate_instance_runtime ~instance_name runtime =
  let pid = runtime.Instance_store.pid in
  try
    Unix.kill pid Sys.sigterm;
    let rec wait_until_stopped attempts_remaining =
      if (not (Process.pid_is_alive pid)) || pid_is_zombie pid then Ok ()
      else if attempts_remaining <= 0 then
        Error
          (Printf.sprintf
             "failed to terminate instance '%s' (pid=%d): process is still \
              running"
             instance_name pid)
      else
        let _ = Unix.select [] [] [] 0.1 in
        wait_until_stopped (attempts_remaining - 1)
    in
    let result = wait_until_stopped 50 in
    (match runtime.Instance_store.passt_pid with
    | Some passt_pid -> kill_if_alive passt_pid
    | None -> ());
    (match runtime.Instance_store.virtiofsd_pid with
    | Some virtiofsd_pid -> kill_if_alive virtiofsd_pid
    | None -> ());
    result
  with Unix.Unix_error (error, _, _) ->
    Error
      (Printf.sprintf "failed to terminate instance '%s' (pid=%d): %s"
         instance_name pid (Unix.error_message error))

let down_command =
  Command.make ~summary:"Stop an instance."
    ~readme:(fun () ->
      "Stop a running instance.\n\
       If INSTANCE is omitted, `default` is used.")
    (let open Command.Std in
     let+ instance_name_opt =
       Arg.pos_opt ~pos:0 Param.string ~docv:"INSTANCE" ~doc:"Instance name."
     in
     Instance_store.reconcile_runtime ();
     let instance_name = resolve_instance_name instance_name_opt in
     match Instance_store.find_runtime instance_name with
     | None ->
         fail
           (Printf.sprintf
              "Instance '%s' is not running. Nothing to stop." instance_name)
     | Some runtime when not (Process.pid_is_alive runtime.pid) ->
         Instance_store.clear_runtime instance_name;
         Printf.printf
           "down: instance=%s was already stopped (stale runtime cleared)\n"
           instance_name
     | Some runtime -> (
         match terminate_instance_runtime ~instance_name runtime with
         | Ok () ->
             Instance_store.clear_runtime instance_name;
             Printf.printf "down: stopped instance=%s\n" instance_name
         | Error message -> fail message))

let rm_command =
  Command.make ~summary:"Remove an instance from state and runtime."
    ~readme:(fun () ->
      "Remove an existing instance.\n\
      \       If INSTANCE is omitted, `default` is used.\n\
      \       If the instance is running, pass --force (or -f) to terminate it \
       first.")
    (let open Command.Std in
     let+ force =
       Arg.flag [ "force"; "f" ]
         ~doc:"Terminate a running instance before removing it."
     and+ instance_name_opt =
       Arg.pos_opt ~pos:0 Param.string ~docv:"INSTANCE" ~doc:"Instance name."
     in
     let instance_name, _target =
       resolve_instance_target ~command_name:"rm" instance_name_opt
     in
     match Instance_store.find_runtime instance_name with
     | Some runtime when Process.pid_is_alive runtime.pid -> (
         if not force then
           fail
             (Printf.sprintf
                "Instance '%s' is running (pid=%d). Stop it first or use `epi \
                 rm --force %s`."
                instance_name runtime.pid instance_name)
         else
           match terminate_instance_runtime ~instance_name runtime with
           | Ok () ->
               Instance_store.remove instance_name;
               Printf.printf "rm: removed instance=%s\n" instance_name
           | Error message -> fail message)
     | Some stale_runtime ->
         (match stale_runtime.Instance_store.passt_pid with
         | Some passt_pid -> kill_if_alive passt_pid
         | None -> ());
         Instance_store.remove instance_name;
         Printf.printf "rm: removed instance=%s\n" instance_name
     | None ->
         Instance_store.remove instance_name;
         Printf.printf "rm: removed instance=%s\n" instance_name)

let list_command =
  Command.make ~summary:"List known instances and their targets."
    (let open Command.Std in
     let+ () = Arg.return () in
     Instance_store.reconcile_runtime ();
     match Instance_store.list () with
     | [] -> print_endline "No instances found."
     | instances ->
         print_endline "INSTANCE\tTARGET";
         List.iter
           (fun (instance_name, target) ->
             Printf.printf "%s\t%s\n" instance_name target)
           instances)

let cmd =
  Command.group
    ~summary:"Manage development VM instances from Nix flake targets."
    ~readme:(fun () ->
      "Instance names identify VMs (`default`, `dev-a`, etc.), while --target \
       identifies flake inputs (<flake-ref>#<config-name>) used during `up`.\n\n\
       Examples:\n\
      \  epi up --target .#default\n\
      \  epi up dev-a --target github:org/repo#dev-a\n\
      \  epi status dev-a\n\
      \  epi rm --force dev-a\n\
      \  epi logs")
    [
      ("up", up_command);
      ( "rebuild",
        lifecycle_command ~name:"rebuild" ~summary:"Rebuild an instance." );
      ("down", down_command);
      ( "status",
        Command.make ~summary:"Show instance status."
          ~readme:(fun () ->
            "Show the status of an instance.\n\
             If INSTANCE is omitted, `default` is used.")
          (let open Command.Std in
           let+ instance_name =
             Arg.pos_opt ~pos:0 Param.string ~docv:"INSTANCE"
               ~doc:"Instance name."
           in
           let instance_name, target =
             resolve_instance_target ~command_name:"status" instance_name
           in
           Printf.printf "status: instance=%s target=%s\n" instance_name target;
           match Instance_store.find_runtime instance_name with
           | Some runtime when Process.pid_is_alive runtime.pid ->
               (match runtime.Instance_store.ssh_port with
               | Some port -> Printf.printf "SSH port: %d\n" port
               | None -> ())
           | _ -> ()) );
      ("rm", rm_command);
      ("console", console_command);
      ("ssh", ssh_command);
      ("logs", lifecycle_command ~name:"logs" ~summary:"Show instance logs.");
      ("list", list_command);
      ("ls", list_command);
    ]
