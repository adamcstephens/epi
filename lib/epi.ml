module Command = Cmdlang.Command

let fail message =
  prerr_endline message;
  exit 1

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
     in
     Instance_store.reconcile_runtime ();
     let instance_name = resolve_instance_name instance_name in
     match Vm_launch.provision ~instance_name ~target with
     | Ok runtime ->
         Instance_store.set_provisioned ~instance_name ~target ~runtime;
         Printf.printf
           "up: provisioned instance=%s target=%s pid=%d serial=%s\n"
           instance_name target runtime.Instance_store.pid runtime.serial_socket
     | Error error -> fail (Vm_launch.pp_provision_error error))

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
     let instance_name = resolve_instance_name instance_name_opt in
     match Instance_store.find_runtime instance_name with
     | None ->
         fail
           (Vm_launch.pp_console_error
              (Vm_launch.Instance_not_running { instance_name }))
     | Some runtime -> (
         if not (Process.pid_is_alive runtime.pid) then (
           Instance_store.clear_runtime instance_name;
           fail
             (Vm_launch.pp_console_error
                (Vm_launch.Instance_not_running { instance_name })))
         else
           match Vm_launch.attach_console ~instance_name runtime with
           | Ok () -> ()
           | Error error -> fail (Vm_launch.pp_console_error error)))

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
      \  epi logs")
    [
      ("up", up_command);
      ( "rebuild",
        lifecycle_command ~name:"rebuild" ~summary:"Rebuild an instance." );
      ("down", lifecycle_command ~name:"down" ~summary:"Stop an instance.");
      ( "status",
        lifecycle_command ~name:"status" ~summary:"Show instance status." );
      ("console", console_command);
      ( "ssh",
        lifecycle_command ~name:"ssh"
          ~summary:"Open SSH session to an instance." );
      ("logs", lifecycle_command ~name:"logs" ~summary:"Show instance logs.");
      ("list", list_command);
    ]
