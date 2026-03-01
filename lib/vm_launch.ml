type descriptor = {
  kernel : string;
  disk : string;
  initrd : string option;
  cpus : int;
  memory_mib : int;
}

type provision_error =
  | Target_resolution_failed of {
      target : string;
      details : string;
      exit_code : int option;
    }
  | Descriptor_validation_failed of { target : string; details : string }
  | Vm_launch_failed of { target : string; exit_code : int; details : string }
  | Vm_disk_lock_held_by_instance of {
      target : string;
      disk : string;
      owner_instance : string;
      owner_pid : int;
    }
  | Vm_disk_lock_held_unknown of { target : string; disk : string }
  | Vm_exited_immediately of { target : string; details : string }

type console_error =
  | Instance_not_running of { instance_name : string }
  | Serial_endpoint_unavailable of {
      instance_name : string;
      endpoint : string;
      details : string;
    }

let contains text snippet =
  let text_len = String.length text in
  let snippet_len = String.length snippet in
  if snippet_len = 0 then true
  else
    let rec loop i =
      if i + snippet_len > text_len then false
      else if String.sub text i snippet_len = snippet then true
      else loop (i + 1)
    in
    loop 0

let lowercase text = String.lowercase_ascii text

let read_file_if_exists path =
  if not (Sys.file_exists path) then ""
  else
    let channel = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in channel)
      (fun () ->
        let buffer = Buffer.create 128 in
        let rec loop () =
          match input_line channel with
          | line ->
              Buffer.add_string buffer line;
              Buffer.add_char buffer '\n';
              loop ()
          | exception End_of_file -> Buffer.contents buffer
        in
        loop ())

let parse_key_value_output text =
  let add_pair acc line =
    match String.split_on_char '=' line with
    | key :: value_parts when key <> "" ->
        let value = String.concat "=" value_parts |> String.trim in
        if value = "" then acc else (String.trim key, value) :: acc
    | _ -> acc
  in
  text |> String.split_on_char '\n' |> List.fold_left add_pair [] |> List.rev

let find_json_string ~key text =
  let marker = "\"" ^ key ^ "\"" in
  match String.index_from_opt text 0 '"' with
  | None -> None
  | Some _ -> (
      match String.index_opt text ':' with
      | None -> None
      | Some _ -> (
          let marker_len = String.length marker in
          let rec find_marker start =
            if start + marker_len > String.length text then None
            else if String.sub text start marker_len = marker then
              Some (start + marker_len)
            else find_marker (start + 1)
          in
          match find_marker 0 with
          | None -> None
          | Some after_marker -> (
              let rec find_quote i =
                if i >= String.length text then None
                else if text.[i] = '"' then Some i
                else find_quote (i + 1)
              in
              match find_quote after_marker with
              | None -> None
              | Some start_quote -> (
                  let rec find_end i =
                    if i >= String.length text then None
                    else if text.[i] = '"' && text.[i - 1] <> '\\' then Some i
                    else find_end (i + 1)
                  in
                  match find_end (start_quote + 1) with
                  | None -> None
                  | Some end_quote ->
                      Some
                        (String.sub text (start_quote + 1)
                           (end_quote - start_quote - 1))))))

let find_json_int ~key text =
  let marker = "\"" ^ key ^ "\"" in
  let marker_len = String.length marker in
  let rec find_marker start =
    if start + marker_len > String.length text then None
    else if String.sub text start marker_len = marker then
      Some (start + marker_len)
    else find_marker (start + 1)
  in
  match find_marker 0 with
  | None -> None
  | Some after_marker -> (
      let rec find_digit i =
        if i >= String.length text then None
        else
          let c = text.[i] in
          if c >= '0' && c <= '9' then Some i else find_digit (i + 1)
      in
      match find_digit after_marker with
      | None -> None
      | Some digit_start ->
          let rec find_end i =
            if i >= String.length text then i
            else
              let c = text.[i] in
              if c >= '0' && c <= '9' then find_end (i + 1) else i
          in
          let digit_end = find_end digit_start in
          int_of_string_opt
            (String.sub text digit_start (digit_end - digit_start)))

let descriptor_of_output raw_output =
  let first_some a b = match a with Some _ -> a | None -> b in
  let kv_pairs = parse_key_value_output raw_output in
  let kv key = List.assoc_opt key kv_pairs in
  let json key = find_json_string ~key raw_output in
  let json_int key = find_json_int ~key raw_output in
  let kernel =
    first_some (kv "kernel") (json "kernel") |> Option.value ~default:""
  in
  let disk = first_some (kv "disk") (json "disk") |> Option.value ~default:"" in
  let initrd = first_some (kv "initrd") (json "initrd") in
  let cpus =
    match
      first_some (Option.bind (kv "cpus") int_of_string_opt) (json_int "cpus")
    with
    | Some value -> value
    | None -> 1
  in
  let memory_mib =
    match
      first_some
        (Option.bind (kv "memory_mib") int_of_string_opt)
        (json_int "memory_mib")
    with
    | Some value -> value
    | None -> 1024
  in
  { kernel; disk; initrd; cpus; memory_mib }

let resolve_descriptor target =
  let process_result =
    match Sys.getenv_opt "EPI_TARGET_RESOLVER_CMD" with
    | Some resolver_cmd ->
        let env = Process.env_with [ ("EPI_TARGET", target) ] in
        Process.run ~env ~prog:"/bin/sh" ~args:[ "-c"; resolver_cmd ] ()
    | None ->
        Process.run ~prog:"nix"
          ~args:[ "eval"; "--json"; target ^ ".config.epi.cloudHypervisor" ]
          ()
  in
  if process_result.status <> 0 then
    Error
      (Target_resolution_failed
         {
           target;
           details =
             (if process_result.stderr = "" then "<no stderr>"
              else process_result.stderr);
           exit_code = Some process_result.status;
         })
  else Ok (descriptor_of_output process_result.stdout)

let store_root_of_path path =
  let prefix = "/nix/store/" in
  if not (String.starts_with ~prefix path) then None
  else
    let rest =
      String.sub path (String.length prefix)
        (String.length path - String.length prefix)
    in
    match String.index_opt rest '/' with
    | None -> Some path
    | Some index -> Some (prefix ^ String.sub rest 0 index)

let ensure_store_realized path =
  match store_root_of_path path with
  | None -> ()
  | Some store_root ->
      let _ =
        Process.run ~prog:"nix-store" ~args:[ "--realise"; store_root ] ()
      in
      ()

let validate_file ~label path =
  if path = "" then Error ("missing launch input: " ^ label)
  else (
    if not (Sys.file_exists path) then ensure_store_realized path;
    if not (Sys.file_exists path) then
      Error ("missing launch input: " ^ label ^ " (" ^ path ^ ")")
    else Ok ())

let validate_descriptor descriptor =
  match validate_file ~label:"kernel" descriptor.kernel with
  | Error _ as error -> error
  | Ok () -> (
      match validate_file ~label:"disk" descriptor.disk with
      | Error _ as error -> error
      | Ok () -> (
          match descriptor.initrd with
          | Some initrd_path -> (
              match validate_file ~label:"initrd" initrd_path with
              | Error _ as error -> error
              | Ok () ->
                  if descriptor.cpus <= 0 then
                    Error "missing launch input: cpus must be > 0"
                  else if descriptor.memory_mib <= 0 then
                    Error "missing launch input: memory_mib must be > 0"
                  else Ok ())
          | None ->
              if descriptor.cpus <= 0 then
                Error "missing launch input: cpus must be > 0"
              else if descriptor.memory_mib <= 0 then
                Error "missing launch input: memory_mib must be > 0"
              else Ok ()))

let lock_conflict stderr =
  let lowered = lowercase stderr in
  contains lowered "lock"
  || contains lowered "resource temporarily unavailable"
  || contains lowered "already in use"

let classify_launch_failure ~target ~descriptor ~status ~stderr =
  if lock_conflict stderr then
    match Instance_store.find_running_owner_by_disk descriptor.disk with
    | Some
        ( owner_instance,
          { Instance_store.pid = owner_pid; serial_socket = _; disk = _ } ) ->
        Vm_disk_lock_held_by_instance
          { target; disk = descriptor.disk; owner_instance; owner_pid }
    | None -> Vm_disk_lock_held_unknown { target; disk = descriptor.disk }
  else
    Vm_launch_failed
      {
        target;
        exit_code = status;
        details = (if stderr = "" then "<no stderr>" else stderr);
      }

let launch_detached ~instance_name ~target descriptor =
  let cloud_hypervisor_bin =
    match Sys.getenv_opt "EPI_CLOUD_HYPERVISOR_BIN" with
    | Some path -> path
    | None -> "cloud-hypervisor"
  in
  let serial_socket = Instance_store.serial_socket_path instance_name in
  let launch_stdout = Instance_store.launch_stdout_path instance_name in
  let launch_stderr = Instance_store.launch_stderr_path instance_name in
  if Sys.file_exists serial_socket then Unix.unlink serial_socket;
  let memory_arg = "size=" ^ string_of_int descriptor.memory_mib ^ "M" in
  let cpu_arg = "boot=" ^ string_of_int descriptor.cpus in
  let serial_arg = "socket=" ^ serial_socket in
  let base_args =
    [
      "--kernel";
      descriptor.kernel;
      "--disk";
      "path=" ^ descriptor.disk;
      "--cpus";
      cpu_arg;
      "--memory";
      memory_arg;
      "--serial";
      serial_arg;
      "--console";
      "off";
      "--cmdline";
      "console=ttyS0 root=/dev/vda2 ro";
    ]
  in
  let args =
    match descriptor.initrd with
    | Some initrd -> base_args @ [ "--initramfs"; initrd ]
    | None -> base_args
  in
  let detached =
    Process.run_detached ~prog:cloud_hypervisor_bin ~args
      ~stdout_path:launch_stdout ~stderr_path:launch_stderr ()
  in
  let _ = Unix.select [] [] [] 0.1 in
  let waited_pid, status = Unix.waitpid [ Unix.WNOHANG ] detached.pid in
  if waited_pid = 0 then
    Ok
      {
        Instance_store.pid = detached.pid;
        serial_socket;
        disk = descriptor.disk;
      }
  else
    let stderr = read_file_if_exists launch_stderr |> String.trim in
    match status with
    | Unix.WEXITED code ->
        Error (classify_launch_failure ~target ~descriptor ~status:code ~stderr)
    | Unix.WSIGNALED signal ->
        Error
          (Vm_exited_immediately
             {
               target;
               details =
                 Printf.sprintf "cloud-hypervisor terminated by signal %d"
                   signal;
             })
    | Unix.WSTOPPED signal ->
        Error
          (Vm_exited_immediately
             {
               target;
               details =
                 Printf.sprintf "cloud-hypervisor stopped (signal %d)" signal;
             })

let provision ~instance_name ~target =
  match resolve_descriptor target with
  | Error _ as error -> error
  | Ok descriptor -> (
      match validate_descriptor descriptor with
      | Error details ->
          Error (Descriptor_validation_failed { target; details })
      | Ok () -> launch_detached ~instance_name ~target descriptor)

let rec write_all fd buffer offset length =
  if length = 0 then ()
  else
    let written = Unix.write fd buffer offset length in
    write_all fd buffer (offset + written) (length - written)

let attach_console ~instance_name runtime =
  let endpoint = runtime.Instance_store.serial_socket in
  let socket = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  let stdin_fd = Unix.descr_of_in_channel stdin in
  let stdout_fd = Unix.descr_of_out_channel stdout in
  let close_socket () = try Unix.close socket with Unix.Unix_error _ -> () in
  let read_and_forward src dst =
    let buffer = Bytes.create 4096 in
    match Unix.read src buffer 0 (Bytes.length buffer) with
    | 0 -> `Eof
    | read_bytes ->
        write_all dst buffer 0 read_bytes;
        `Ok
  in
  try
    Unix.connect socket (Unix.ADDR_UNIX endpoint);
    let rec loop read_stdin =
      let read_fds = if read_stdin then [ socket; stdin_fd ] else [ socket ] in
      let ready, _, _ = Unix.select read_fds [] [] (-1.0) in
      let read_stdin =
        if read_stdin && List.exists (( = ) stdin_fd) ready then
          match read_and_forward stdin_fd socket with
          | `Eof ->
              Unix.shutdown socket Unix.SHUTDOWN_SEND;
              false
          | `Ok -> true
        else read_stdin
      in
      let socket_open =
        if List.exists (( = ) socket) ready then
          match read_and_forward socket stdout_fd with
          | `Eof -> false
          | `Ok -> true
        else true
      in
      if socket_open then loop read_stdin
    in
    loop true;
    close_socket ();
    Ok ()
  with Unix.Unix_error (error, _, _) ->
    close_socket ();
    Error
      (Serial_endpoint_unavailable
         { instance_name; endpoint; details = Unix.error_message error })

let pp_provision_error = function
  | Target_resolution_failed { target; details; exit_code = Some exit_code } ->
      Printf.sprintf "target resolution failed for %s (exit=%d): %s" target
        exit_code details
  | Target_resolution_failed { target; details; exit_code = None } ->
      Printf.sprintf "target resolution failed for %s: %s" target details
  | Descriptor_validation_failed { target; details } ->
      Printf.sprintf "descriptor validation failed for %s: %s" target details
  | Vm_launch_failed { target; exit_code; details } ->
      Printf.sprintf "VM launch failed for %s (exit=%d): %s" target exit_code
        details
  | Vm_disk_lock_held_by_instance { target; disk; owner_instance; owner_pid } ->
      Printf.sprintf
        "VM launch failed for %s: another running VM already holds disk lock \
         %s (owner=%s pid=%d). Stop that instance and retry."
        target disk owner_instance owner_pid
  | Vm_disk_lock_held_unknown { target; disk } ->
      Printf.sprintf
        "VM launch failed for %s: disk image is already locked by another \
         process (%s). Check for external cloud-hypervisor processes."
        target disk
  | Vm_exited_immediately { target; details } ->
      Printf.sprintf "VM launch failed for %s: %s" target details

let pp_console_error = function
  | Instance_not_running { instance_name } ->
      Printf.sprintf
        "Instance '%s' is not running. Run `epi up %s --target <flake#config>` \
         first."
        instance_name instance_name
  | Serial_endpoint_unavailable { instance_name; endpoint; details } ->
      Printf.sprintf
        "Serial endpoint unavailable for '%s' at %s: %s. Check VM runtime \
         state for '%s'."
        instance_name endpoint details instance_name
