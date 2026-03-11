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

let resolve_no_wait no_wait_flag =
  if no_wait_flag then true
  else
    match Sys.getenv_opt "EPI_NO_WAIT" with
    | Some s -> (
        match parse_env_boolean s with
        | Some v -> v
        | None ->
            fail (Printf.sprintf "Invalid EPI_NO_WAIT=%S. Use true/false." s))
    | None -> false

let resolve_wait_timeout wait_timeout_opt =
  match wait_timeout_opt with
  | Some t -> t
  | None ->
      match Sys.getenv_opt "EPI_WAIT_TIMEOUT_SECONDS" with
      | Some s -> (
          match int_of_string_opt (String.trim s) with
          | Some t when t > 0 -> t
          | _ ->
              fail
                (Printf.sprintf
                   "Invalid EPI_WAIT_TIMEOUT_SECONDS=%S. Expected a positive integer."
                   s))
      | None -> 120

let resolve_instance_name instance_name_opt =
  match instance_name_opt with
  | Some instance_name -> instance_name
  | None -> Instance_store.default_instance_name

let resolve_instance_target ~command_name instance_name_opt =
  let instance_name = resolve_instance_name instance_name_opt in
  match Instance_store.find instance_name with
  | Some target -> (instance_name, target)
  | None when instance_name_opt = None ->
      fail
        (Printf.sprintf
           "Instance '%s' was not found. Run `epi launch --target <flake#config>` \
            to create it, or pass an instance name (for example: `epi %s \
            <instance>`)."
           Instance_store.default_instance_name command_name)
  | None ->
      fail
        (Printf.sprintf
           "Instance '%s' was not found. Run `epi list` to see known \
            instances, or create it with `epi launch %s --target <flake#config>`."
           instance_name instance_name)

let instance_is_running ~instance_name runtime =
  match Instance_store.vm_unit_name ~instance_name ~unit_id:runtime.Instance_store.unit_id with
  | Ok unit_name -> Process.unit_is_active unit_name
  | Error _ -> false

let stop_instance ~instance_name runtime =
  let unit_id = runtime.Instance_store.unit_id in
  (match Instance_store.vm_unit_name ~instance_name ~unit_id with
   | Ok vm_unit -> ignore (Process.stop_unit vm_unit)
   | Error _ -> ());
  match Instance_store.slice_name ~instance_name ~unit_id with
  | Ok slice -> Process.stop_unit slice
  | Error _ -> false

let attach_console_for_running_instance ~instance_name ~options runtime =
  if not (instance_is_running ~instance_name runtime) then (
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

let provision_and_report ~command_name ~attach_console ~console_options
    ~rebuild ~no_wait ~wait_timeout ~mount_paths ~disk_size ~instance_name ~target =
  match Vm_launch.provision ~rebuild ~mount_paths ~disk_size
          ~instance_name ~target with
  | Error error -> fail (Vm_launch.pp_provision_error error)
  | Ok runtime ->
      Instance_store.set_provisioned ~instance_name ~target ~runtime;
      if not no_wait then (
        match runtime.Instance_store.ssh_port with
        | Some ssh_port ->
            Printf.printf "vm: waiting for SSH (timeout %ds)...\n%!" wait_timeout;
            (match Vm_launch.wait_for_ssh ~ssh_port
                     ~ssh_key_path:runtime.Instance_store.ssh_key_path
                     ~timeout_seconds:wait_timeout with
            | Ok () -> Printf.printf "vm: SSH ready\n%!"
            | Error error -> fail (Vm_launch.pp_provision_error error))
        | None -> ());
      if attach_console then
        attach_console_for_running_instance ~instance_name
          ~options:console_options runtime
      else (
        Printf.printf "%s: provisioned instance=%s target=%s unit_id=%s serial=%s\n"
          command_name instance_name target runtime.Instance_store.unit_id
          runtime.serial_socket;
        match runtime.Instance_store.ssh_port with
        | Some port -> Printf.printf "SSH port: %d\n" port
        | None -> ())

let launch_command =
  Command.make ~summary:"Create or start an instance from a flake target."
    ~readme:(fun () ->
      "Use an optional instance name plus --target <flake-ref>#<config-name>.\n\
       If no instance name is provided, the instance defaults to `default`.\n\n\
       Examples:\n\
      \  epi launch --target .#dev\n\
      \  epi launch dev-a --target github:org/repo#dev-a")
    (let open Command.Std in
     let+ instance_name =
       Arg.pos_opt ~pos:0 Param.string ~docv:"INSTANCE" ~doc:"Instance name."
     and+ target =
       Arg.named_opt [ "target" ] Param.string
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
     and+ mount_paths =
       Arg.named_multi [ "mount" ] Param.string
         ~docv:"PATH"
         ~doc:
           "Mount a host directory into the guest at the same path using \
            virtiofsd. Can be repeated for multiple directories."
     and+ disk_size =
       Arg.named_opt [ "disk-size" ] Param.string
         ~docv:"SIZE"
         ~doc:
           "Target size of the writable disk overlay (e.g. 40G, 50G). Only \
            applies when a new overlay is created. Defaults to 40G."
     and+ no_wait =
       Arg.flag [ "no-wait" ]
         ~doc:
           "Return immediately after the VM process starts without waiting \
            for SSH connectivity."
     and+ wait_timeout =
       Arg.named_opt [ "wait-timeout" ] Param.int
         ~docv:"SECONDS"
         ~doc:
           "Maximum seconds to wait for SSH connectivity (default 120). \
            Overrides EPI_WAIT_TIMEOUT_SECONDS."
     in
     let config = match Config.load () with
       | Ok c -> c
       | Error msg -> fail msg
     in
     let cli_mounts =
       let cwd = Sys.getcwd () in
       List.map (Config.resolve_path ~base:cwd) mount_paths
     in
     let merged = match Config.merge ~cli_target:target ~cli_mounts ~cli_disk_size:disk_size config with
       | Ok m -> m
       | Error msg -> fail msg
     in
     let target = match Target.of_string merged.Config.resolved_target with
       | Ok t -> Target.to_string t
       | Error (`Msg msg) -> fail msg
     in
     let mount_paths = merged.Config.resolved_mounts in
     let disk_size = merged.Config.resolved_disk_size in
     let console_options = resolve_console_attach_options () in
     let no_wait = resolve_no_wait no_wait in
     let wait_timeout = resolve_wait_timeout wait_timeout in
     let instance_name = resolve_instance_name instance_name in
     match Instance_store.find_runtime instance_name with
     | Some runtime when instance_is_running ~instance_name runtime ->
         if attach_console then (
           Printf.printf
             "launch: instance=%s target=%s already-running unit_id=%s, attaching \
              console\n%!"
             instance_name target runtime.unit_id;
           attach_console_for_running_instance ~instance_name
             ~options:console_options runtime)
         else
           Printf.printf
             "launch: instance=%s target=%s already-running unit_id=%s serial=%s\n"
             instance_name target runtime.unit_id runtime.serial_socket
     | Some stale_runtime ->
         ignore (stop_instance ~instance_name stale_runtime);
         Instance_store.clear_runtime instance_name;
         provision_and_report ~command_name:"launch" ~attach_console ~console_options
           ~rebuild ~no_wait ~wait_timeout ~mount_paths ~disk_size ~instance_name ~target
     | None ->
         provision_and_report ~command_name:"launch" ~attach_console ~console_options
           ~rebuild ~no_wait ~wait_timeout ~mount_paths ~disk_size ~instance_name ~target)

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
     let instance_name = resolve_instance_name instance_name_opt in
     match Instance_store.find_runtime instance_name with
     | None ->
         fail
           (Printf.sprintf "Instance '%s' is not running. Start it with: epi start"
              instance_name)
     | Some runtime when not (instance_is_running ~instance_name runtime) ->
         fail
           (Printf.sprintf "Instance '%s' is not running. Start it with: epi start"
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
             let args =
               [| "ssh"; "-p"; port_str;
                  "-i"; runtime.Instance_store.ssh_key_path;
                  "-o"; "StrictHostKeyChecking=no";
                  "-o"; "UserKnownHostsFile=/dev/null";
                  target |]
             in
             Unix.execvp "ssh" args))

let exec_command =
  Command.make ~summary:"Execute a command in an instance."
    ~readme:(fun () ->
      "Run a command inside a running instance via SSH.\n\
       If INSTANCE is omitted, `default` is used.\n\n\
       Examples:\n\
      \  epi exec -- ls /tmp\n\
      \  epi exec dev-a -- uname -a")
    (let open Command.Std in
     let+ args =
       Arg.pos_all Param.string ~docv:"[INSTANCE] -- COMMAND [ARGS...]"
         ~doc:
           "Optional instance name, then `--`, then the command to execute."
     in
     let instance_name, cmd_args =
       match args with
       | [] -> fail "exec requires a command. Usage: epi exec [INSTANCE] -- COMMAND [ARGS...]"
       | first :: rest -> (
           match Instance_store.find first with
           | Some _ when rest <> [] -> (first, rest)
           | Some _ -> fail "exec requires a command. Usage: epi exec [INSTANCE] -- COMMAND [ARGS...]"
           | None -> (Instance_store.default_instance_name, args))
     in
     match Instance_store.find_runtime instance_name with
     | None ->
         fail
           (Printf.sprintf "Instance '%s' is not running. Start it with: epi start"
              instance_name)
     | Some runtime when not (instance_is_running ~instance_name runtime) ->
         fail
           (Printf.sprintf "Instance '%s' is not running. Start it with: epi start"
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
             let args =
               Array.concat
                 [
                   [| "ssh"; "-T"; "-p"; port_str;
                      "-i"; runtime.Instance_store.ssh_key_path;
                      "-o"; "StrictHostKeyChecking=no";
                      "-o"; "UserKnownHostsFile=/dev/null";
                      target |];
                   Array.of_list cmd_args;
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
  if stop_instance ~instance_name runtime then Ok ()
  else
    Error
      (Printf.sprintf
         "failed to terminate instance '%s' (unit_id=%s): systemctl stop failed"
         instance_name runtime.Instance_store.unit_id)

let stop_command =
  Command.make ~summary:"Stop an instance."
    ~readme:(fun () ->
      "Stop a running instance.\n\
       If INSTANCE is omitted, `default` is used.")
    (let open Command.Std in
     let+ instance_name_opt =
       Arg.pos_opt ~pos:0 Param.string ~docv:"INSTANCE" ~doc:"Instance name."
     in
     let instance_name = resolve_instance_name instance_name_opt in
     match Instance_store.find_runtime instance_name with
     | None ->
         fail
           (Printf.sprintf
              "Instance '%s' is not running. Nothing to stop." instance_name)
     | Some runtime when not (instance_is_running ~instance_name runtime) ->
         Instance_store.clear_runtime instance_name;
         Printf.printf
           "stop: instance=%s was already stopped (stale runtime cleared)\n"
           instance_name
     | Some runtime -> (
         match terminate_instance_runtime ~instance_name runtime with
         | Ok () ->
             Instance_store.clear_runtime instance_name;
             Printf.printf "stop: stopped instance=%s\n" instance_name
         | Error message -> fail message))

let start_command =
  Command.make ~summary:"Start an existing stopped instance."
    ~readme:(fun () ->
      "Start a stopped instance using its stored target.\n\
       If INSTANCE is omitted, `default` is used.\n\n\
       Unlike `launch`, no --target is required — the target from the previous\n\
       `launch` is reused. Use `launch` to create a new instance or change its target.\n\n\
       Examples:\n\
      \  epi start\n\
      \  epi start dev-a\n\
      \  epi start dev-a --console")
    (let open Command.Std in
     let+ instance_name_opt =
       Arg.pos_opt ~pos:0 Param.string ~docv:"INSTANCE" ~doc:"Instance name."
     and+ attach_console =
       Arg.flag [ "console" ]
         ~doc:
           "Attach to the instance serial console immediately after starting."
     and+ no_wait =
       Arg.flag [ "no-wait" ]
         ~doc:
           "Return immediately after the VM process starts without waiting \
            for SSH connectivity."
     and+ wait_timeout =
       Arg.named_opt [ "wait-timeout" ] Param.int
         ~docv:"SECONDS"
         ~doc:
           "Maximum seconds to wait for SSH connectivity (default 120). \
            Overrides EPI_WAIT_TIMEOUT_SECONDS."
     in
     let console_options = resolve_console_attach_options () in
     let no_wait = resolve_no_wait no_wait in
     let wait_timeout = resolve_wait_timeout wait_timeout in
     let instance_name = resolve_instance_name instance_name_opt in
     let target =
       match Instance_store.find instance_name with
       | Some t -> t
       | None when instance_name_opt = None ->
           fail
             (Printf.sprintf
                "Instance '%s' was not found. Run `epi launch --target \
                 <flake#config>` to create it, or pass an instance name (for \
                 example: `epi start <instance>`)."
                Instance_store.default_instance_name)
       | None ->
           fail
             (Printf.sprintf
                "Instance '%s' was not found. Run `epi list` to see known \
                 instances, or create it with `epi launch %s --target \
                 <flake#config>`."
                instance_name instance_name)
     in
     match Instance_store.find_runtime instance_name with
     | Some runtime when instance_is_running ~instance_name runtime ->
         if attach_console then (
           Printf.printf
             "start: instance=%s already-running unit_id=%s, attaching console\n%!"
             instance_name runtime.unit_id;
           attach_console_for_running_instance ~instance_name
             ~options:console_options runtime)
         else
           Printf.printf "start: instance=%s already-running unit_id=%s serial=%s\n"
             instance_name runtime.unit_id runtime.serial_socket
     | Some stale_runtime ->
         ignore (stop_instance ~instance_name stale_runtime);
         Instance_store.clear_runtime instance_name;
         provision_and_report ~command_name:"start" ~attach_console ~console_options
           ~rebuild:false ~no_wait ~wait_timeout
           ~mount_paths:(Instance_store.load_mounts instance_name) ~disk_size:"40G"
           ~instance_name ~target
     | None ->
         provision_and_report ~command_name:"start" ~attach_console ~console_options
           ~rebuild:false ~no_wait ~wait_timeout
           ~mount_paths:(Instance_store.load_mounts instance_name) ~disk_size:"40G"
           ~instance_name ~target)

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
     | Some runtime when instance_is_running ~instance_name runtime -> (
         if not force then
           fail
             (Printf.sprintf
                "Instance '%s' is running (unit_id=%s). Stop it first or use `epi \
                 rm --force %s`."
                instance_name runtime.unit_id instance_name)
         else
           match terminate_instance_runtime ~instance_name runtime with
           | Ok () ->
               Instance_store.remove instance_name;
               Printf.printf "rm: removed instance=%s\n" instance_name
           | Error message -> fail message)
     | Some stale_runtime ->
         ignore (stop_instance ~instance_name stale_runtime);
         Instance_store.remove instance_name;
         Printf.printf "rm: removed instance=%s\n" instance_name
     | None ->
         Instance_store.remove instance_name;
         Printf.printf "rm: removed instance=%s\n" instance_name)

let list_command =
  Command.make ~summary:"List known instances and their targets."
    (let open Command.Std in
     let+ () = Arg.return () in
     match Instance_store.list () with
     | [] -> print_endline "No instances found."
     | instances ->
         print_endline "INSTANCE\tTARGET\tSTATUS\tSSH";
         List.iter
           (fun (instance_name, target) ->
             let status, ssh =
               match Instance_store.find_runtime instance_name with
               | Some runtime when instance_is_running ~instance_name runtime ->
                   let ssh_str =
                     match runtime.Instance_store.ssh_port with
                     | Some port -> string_of_int port
                     | None -> "-"
                   in
                   ("running", ssh_str)
               | _ -> ("stopped", "-")
             in
             Printf.printf "%s\t%s\t%s\t%s\n" instance_name target status ssh)
           instances)

let cmd =
  Command.group
    ~summary:"Manage development VM instances from Nix flake targets."
    ~readme:(fun () ->
      "Instance names identify VMs (`default`, `dev-a`, etc.), while --target \
       identifies flake inputs (<flake-ref>#<config-name>) used during `launch`.\n\n\
       Examples:\n\
      \  epi launch --target .#default\n\
      \  epi launch dev-a --target github:org/repo#dev-a\n\
      \  epi start dev-a\n\
      \  epi stop dev-a\n\
      \  epi status dev-a\n\
      \  epi rm --force dev-a\n\
      \  epi logs")
    [
      ("launch", launch_command);
      ("start", start_command);
      ( "rebuild",
        lifecycle_command ~name:"rebuild" ~summary:"Rebuild an instance." );
      ("stop", stop_command);
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
           match Instance_store.find_runtime instance_name with
           | Some runtime when instance_is_running ~instance_name runtime ->
               Printf.printf "Instance: %s\n" instance_name;
               Printf.printf "Target:   %s\n" target;
               Printf.printf "Status:   running\n";
               (match runtime.Instance_store.ssh_port with
               | Some port -> Printf.printf "SSH port: %d\n" port
               | None -> ());
               Printf.printf "Serial:   %s\n" runtime.Instance_store.serial_socket;
               Printf.printf "Disk:     %s\n" runtime.Instance_store.disk;
               Printf.printf "Unit ID:  %s\n" runtime.Instance_store.unit_id
           | _ ->
               Printf.printf "Instance: %s\n" instance_name;
               Printf.printf "Target:   %s\n" target;
               Printf.printf "Status:   stopped\n") );
      ("rm", rm_command);
      ("console", console_command);
      ("ssh", ssh_command);
      ("exec", exec_command);
      ("logs", lifecycle_command ~name:"logs" ~summary:"Show instance logs.");
      ("list", list_command);
      ("ls", list_command);
    ]

module Instance_store = Instance_store
module Vm_launch = Vm_launch
module Process = Process
