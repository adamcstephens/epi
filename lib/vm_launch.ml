type descriptor = {
  kernel : string;
  disk : string;
  initrd : string option;
  cmdline : string;
  cpus : int;
  memory_mib : int;
}

let default_cmdline = "console=ttyS0 root=/dev/vda2 ro"

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
  | Vm_disk_overlay_prepare_failed of { target : string; details : string }
  | Seed_iso_generation_failed of { target : string; details : string }
  | Pasta_missing of { target : string }
  | Pasta_socket_unavailable of { target : string; socket : string }

type console_error =
  | Instance_not_running of { instance_name : string }
  | Serial_endpoint_unavailable of {
      instance_name : string;
      endpoint : string;
      details : string;
    }
  | Console_capture_failed of {
      instance_name : string;
      capture_path : string;
      details : string;
    }
  | Console_session_timed_out of {
      instance_name : string;
      timeout_seconds : float;
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
  let cmdline =
    first_some (kv "cmdline") (json "cmdline")
    |> Option.value ~default:default_cmdline
  in
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
  { kernel; disk; initrd; cmdline; cpus; memory_mib }

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

let split_target target =
  match String.index_opt target '#' with
  | None -> None
  | Some hash_index ->
      let flake_ref = String.sub target 0 hash_index in
      let config_name =
        String.sub target (hash_index + 1)
          (String.length target - hash_index - 1)
      in
      if flake_ref = "" || config_name = "" then None
      else Some (flake_ref, config_name)

let build_target_artifact_if_missing ~target ~label =
  match split_target target with
  | None -> ()
  | Some (flake_ref, config_name) ->
      let build_target =
        match label with
        | "kernel" ->
            flake_ref ^ "#" ^ config_name ^ ".config.system.build.kernel"
        | "disk" ->
            flake_ref ^ "#" ^ config_name ^ ".config.system.build.images.qemu"
        | "initrd" ->
            flake_ref ^ "#" ^ config_name
            ^ ".config.system.build.initialRamdisk"
        | _ -> ""
      in
      if build_target <> "" then
        let _ = Process.run ~prog:"nix" ~args:[ "build"; build_target ] () in
        ()

let validate_file ~target ~label path =
  if path = "" then Error ("missing launch input: " ^ label)
  else (
    if not (Sys.file_exists path) then (
      Printf.printf "up: building %s\n%!" label;
      ensure_store_realized path);
    if not (Sys.file_exists path) then
      build_target_artifact_if_missing ~target ~label;
    if not (Sys.file_exists path) then ensure_store_realized path;
    if not (Sys.file_exists path) then
      Error ("missing launch input: " ^ label ^ " (" ^ path ^ ")")
    else Ok ())

let is_nix_store_path path = String.starts_with ~prefix:"/nix/store/" path

let descriptor_paths descriptor =
  let base_paths = [ descriptor.kernel; descriptor.disk ] in
  match descriptor.initrd with
  | Some initrd_path -> initrd_path :: base_paths
  | None -> base_paths

let all_paths_share_parent descriptor =
  match descriptor_paths descriptor with
  | [] -> true
  | first_path :: rest ->
      let first_parent = Filename.dirname first_path in
      List.for_all
        (fun path -> String.equal (Filename.dirname path) first_parent)
        rest

let validate_descriptor_coherence descriptor =
  let kernel_is_store = is_nix_store_path descriptor.kernel in
  let disk_is_store = is_nix_store_path descriptor.disk in
  let initrd_is_store =
    match descriptor.initrd with
    | Some initrd_path -> is_nix_store_path initrd_path
    | None -> true
  in
  let any_store_path =
    kernel_is_store || disk_is_store
    || match descriptor.initrd with Some _ -> initrd_is_store | None -> false
  in
  if
    any_store_path
    && ((not kernel_is_store) || (not disk_is_store) || not initrd_is_store)
  then
    Error
      "launch inputs are not coherent: kernel/initrd/disk must all come from \
       target outputs in /nix/store; fix target outputs and rebuild instead of \
       reusing an external mutable disk image"
  else if (not any_store_path) && not (all_paths_share_parent descriptor) then
    Error
      "launch inputs are not coherent: kernel/initrd/disk must come from the \
       same target-built output set; fix target outputs and rebuild instead of \
       reusing an external mutable disk image"
  else Ok ()

let validate_descriptor ~target descriptor =
  match validate_file ~target ~label:"kernel" descriptor.kernel with
  | Error _ as error -> error
  | Ok () -> (
      match validate_file ~target ~label:"disk" descriptor.disk with
      | Error _ as error -> error
      | Ok () -> (
          match descriptor.initrd with
          | Some initrd_path -> (
              match validate_file ~target ~label:"initrd" initrd_path with
              | Error _ as error -> error
              | Ok () ->
                  if descriptor.cpus <= 0 then
                    Error "missing launch input: cpus must be > 0"
                  else if descriptor.memory_mib <= 0 then
                    Error "missing launch input: memory_mib must be > 0"
                  else validate_descriptor_coherence descriptor)
          | None ->
              if descriptor.cpus <= 0 then
                Error "missing launch input: cpus must be > 0"
              else if descriptor.memory_mib <= 0 then
                Error "missing launch input: memory_mib must be > 0"
              else validate_descriptor_coherence descriptor))

let lock_conflict stderr =
  let lowered = lowercase stderr in
  contains lowered "locked"
  || contains lowered "lock conflict"
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

let copy_file ~source ~destination =
  let input_channel = open_in_bin source in
  Fun.protect
    ~finally:(fun () -> close_in_noerr input_channel)
    (fun () ->
      let output_channel = open_out_bin destination in
      Fun.protect
        ~finally:(fun () -> close_out_noerr output_channel)
        (fun () ->
          let buffer = Bytes.create 1_048_576 in
          let rec loop () =
            let read_bytes =
              input input_channel buffer 0 (Bytes.length buffer)
            in
            if read_bytes > 0 then (
              output output_channel buffer 0 read_bytes;
              loop ())
          in
          loop ()))

let ensure_writable_disk ~instance_name ~target descriptor =
  if is_nix_store_path descriptor.disk then
    let overlay_path =
      Filename.concat
        (Instance_store.runtime_dir ())
        (instance_name ^ ".disk.img")
    in
    if Sys.file_exists overlay_path then Ok overlay_path
    else (
      Process.ensure_parent_dir overlay_path;
      try
        copy_file ~source:descriptor.disk ~destination:overlay_path;
        Ok overlay_path
      with Sys_error details ->
        Error (Vm_disk_overlay_prepare_failed { target; details }))
  else Ok descriptor.disk

let read_ssh_public_keys () =
  let ssh_dir =
    match Sys.getenv_opt "EPI_SSH_DIR" with
    | Some dir -> Some dir
    | None -> (
        match Sys.getenv_opt "HOME" with
        | Some home -> Some (Filename.concat home ".ssh")
        | None -> None)
  in
  match ssh_dir with
  | None ->
      Printf.eprintf
        "warning: HOME not set, cannot read SSH public keys\n%!";
      []
  | Some ssh_dir ->
      if not (Sys.file_exists ssh_dir) then (
        Printf.eprintf
          "warning: no SSH public keys found (no ~/.ssh directory)\n%!";
        [])
      else
        let entries = Sys.readdir ssh_dir |> Array.to_list in
        let pub_files =
          List.filter
            (fun name ->
              let len = String.length name in
              len > 4 && String.sub name (len - 4) 4 = ".pub")
            entries
        in
        let keys =
          List.filter_map
            (fun name ->
              let path = Filename.concat ssh_dir name in
              let content = read_file_if_exists path |> String.trim in
              if content = "" then None else Some content)
            pub_files
        in
        if keys = [] then
          Printf.eprintf
            "warning: no SSH public keys found in ~/.ssh/*.pub\n%!";
        keys

let generate_user_data ~username ~ssh_keys =
  let buf = Buffer.create 256 in
  Buffer.add_string buf "#cloud-config\ndisable_root: false\nusers:\n";
  Buffer.add_string buf (Printf.sprintf "  - name: %s\n" username);
  Buffer.add_string buf "    groups: wheel\n";
  Buffer.add_string buf "    sudo: ALL=(ALL) NOPASSWD:ALL\n";
  Buffer.add_string buf "    shell: /bin/bash\n";
  (match ssh_keys with
  | [] -> ()
  | keys ->
      Buffer.add_string buf "    ssh_authorized_keys:\n";
      List.iter
        (fun key ->
          Buffer.add_string buf (Printf.sprintf "      - %s\n" key))
        keys);
  Buffer.contents buf

let generate_meta_data ~instance_name =
  Printf.sprintf "instance-id: %s\nlocal-hostname: %s\n" instance_name
    instance_name

type seed_iso_error =
  | Genisoimage_missing
  | Seed_iso_creation_failed of { details : string }

let genisoimage_bin () =
  match Sys.getenv_opt "EPI_GENISOIMAGE_BIN" with
  | Some path -> path
  | None -> "genisoimage"

let check_genisoimage () =
  let bin = genisoimage_bin () in
  let result =
    Process.run ~prog:"sh"
      ~args:[ "-c"; "command -v " ^ bin ]
      ()
  in
  result.status = 0

let passt_bin () =
  match Sys.getenv_opt "EPI_PASST_BIN" with
  | Some path -> path
  | None -> "passt"

let check_passt () =
  let bin = passt_bin () in
  let result =
    Process.run ~prog:"sh" ~args:[ "-c"; "command -v " ^ bin ] ()
  in
  result.status = 0

let wait_for_pasta_socket socket_path max_wait_ms =
  let step_ms = 50 in
  let steps = max_wait_ms / step_ms in
  let rec loop n =
    if Sys.file_exists socket_path then true
    else if n = 0 then false
    else
      let _ = Unix.select [] [] [] (float_of_int step_ms /. 1000.0) in
      loop (n - 1)
  in
  loop steps

let generate_seed_iso ~instance_name ~runtime_dir ~username ~ssh_keys =
  if not (check_genisoimage ()) then Error Genisoimage_missing
  else
    let iso_path =
      Filename.concat runtime_dir (instance_name ^ ".cidata.iso")
    in
    let staging_dir =
      Filename.concat runtime_dir (instance_name ^ ".cidata")
    in
    Process.ensure_parent_dir iso_path;
    (if not (Sys.file_exists staging_dir) then
       Unix.mkdir staging_dir 0o755);
    let user_data_path = Filename.concat staging_dir "user-data" in
    let meta_data_path = Filename.concat staging_dir "meta-data" in
    let user_data = generate_user_data ~username ~ssh_keys in
    let meta_data = generate_meta_data ~instance_name in
    let write path content =
      let channel = open_out path in
      output_string channel content;
      close_out channel
    in
    write user_data_path user_data;
    write meta_data_path meta_data;
    let result =
      Process.run ~prog:(genisoimage_bin ())
        ~args:
          [
            "-output";
            iso_path;
            "-volid";
            "cidata";
            "-joliet";
            "-rock";
            user_data_path;
            meta_data_path;
          ]
        ()
    in
    if result.status <> 0 then
      Error
        (Seed_iso_creation_failed
           {
             details =
               (if result.stderr = "" then "<no stderr>" else result.stderr);
           })
    else Ok iso_path

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
  let memory_arg = "size=" ^ string_of_int descriptor.memory_mib ^ "M,shared=on" in
  let cpu_arg = "boot=" ^ string_of_int descriptor.cpus in
  let serial_arg = "socket=" ^ serial_socket in
  let username =
    match Sys.getenv_opt "USER" with Some u -> u | None -> "user"
  in
  let runtime_dir = Instance_store.runtime_dir () in
  let ssh_keys = read_ssh_public_keys () in
  let pasta_sock =
    Filename.concat runtime_dir (instance_name ^ ".passt.sock")
  in
  if not (check_passt ()) then Error (Pasta_missing { target })
  else
  match generate_seed_iso ~instance_name ~runtime_dir ~username ~ssh_keys with
  | Error Genisoimage_missing ->
      Error
        (Seed_iso_generation_failed
           {
             target;
             details =
               "genisoimage not found on $PATH. Install cdrkit to enable \
                cloud-init seed ISO generation.";
           })
  | Error (Seed_iso_creation_failed { details }) ->
      Error (Seed_iso_generation_failed { target; details })
  | Ok seed_iso_path ->
  match ensure_writable_disk ~instance_name ~target descriptor with
  | Error _ as error -> error
  | Ok launch_disk -> (
      if Sys.file_exists pasta_sock then Unix.unlink pasta_sock;
      let pasta_repair_sock = pasta_sock ^ ".repair" in
      if Sys.file_exists pasta_repair_sock then Unix.unlink pasta_repair_sock;
      let _pasta_proc =
        Process.run_detached ~prog:(passt_bin ())
          ~args:[ "--vhost-user"; "--socket"; pasta_sock ]
          ~stdout_path:
            (Filename.concat runtime_dir (instance_name ^ ".pasta.stdout.log"))
          ~stderr_path:
            (Filename.concat runtime_dir (instance_name ^ ".pasta.stderr.log"))
          ()
      in
      if not (wait_for_pasta_socket pasta_sock 2000) then
        Error (Pasta_socket_unavailable { target; socket = pasta_sock })
      else
      let disk_arg = "path=" ^ launch_disk in
      let seed_disk_arg = "path=" ^ seed_iso_path ^ ",readonly=on" in
      let net_arg =
        "vhost_user=true,socket=" ^ pasta_sock ^ ",vhost_mode=client"
      in
      let base_args =
        [
          "--kernel";
          descriptor.kernel;
          "--disk";
          disk_arg;
          seed_disk_arg;
        ]
        @ [
          "--cpus";
          cpu_arg;
          "--memory";
          memory_arg;
          "--serial";
          serial_arg;
          "--console";
          "off";
          "--cmdline";
          descriptor.cmdline;
          "--net";
          net_arg;
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
            disk = launch_disk;
          }
      else
        let stderr = read_file_if_exists launch_stderr |> String.trim in
        match status with
        | Unix.WEXITED code ->
            Error
              (classify_launch_failure ~target ~descriptor ~status:code ~stderr)
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
                     Printf.sprintf "cloud-hypervisor stopped (signal %d)"
                       signal;
                 }))

let provision ~instance_name ~target =
  Printf.printf "up: evaluating target=%s\n%!" target;
  match resolve_descriptor target with
  | Error _ as error -> error
  | Ok descriptor -> (
      Printf.printf "up: building target artifacts\n%!";
      match validate_descriptor ~target descriptor with
      | Error details ->
          Error (Descriptor_validation_failed { target; details })
      | Ok () ->
          Printf.printf "up: starting VM instance=%s\n%!" instance_name;
          launch_detached ~instance_name ~target descriptor)

let rec write_all fd buffer offset length =
  if length = 0 then ()
  else
    let written = Unix.write fd buffer offset length in
    write_all fd buffer (offset + written) (length - written)

let rec connect_serial_socket socket endpoint attempts_remaining =
  try
    Unix.connect socket (Unix.ADDR_UNIX endpoint);
    Ok ()
  with
  | Unix.Unix_error ((Unix.ENOENT | Unix.ECONNREFUSED), _, _)
    when attempts_remaining > 0 ->
      let _ = Unix.select [] [] [] 0.05 in
      connect_serial_socket socket endpoint (attempts_remaining - 1)
  | Unix.Unix_error (error, _, _) -> Error (Unix.error_message error)

let attach_console ?(read_stdin = true) ?capture_path ?timeout_seconds
    ~instance_name runtime =
  let endpoint = runtime.Instance_store.serial_socket in
  let socket = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  let stdout_fd = Unix.descr_of_out_channel stdout in
  let stdin_fd = Unix.descr_of_in_channel stdin in
  let close_socket () = try Unix.close socket with Unix.Unix_error _ -> () in
  let write_capture capture_channel buffer read_bytes =
    output capture_channel buffer 0 read_bytes;
    flush capture_channel
  in
  let read_and_forward src dst capture_channel_opt =
    let buffer = Bytes.create 4096 in
    match Unix.read src buffer 0 (Bytes.length buffer) with
    | 0 -> `Eof
    | read_bytes ->
        write_all dst buffer 0 read_bytes;
        (match capture_channel_opt with
        | Some capture_channel ->
            write_capture capture_channel buffer read_bytes
        | None -> ());
        `Ok
  in
  let open_capture_channel capture =
    try Ok (open_out_gen [ Open_creat; Open_trunc; Open_wronly ] 0o644 capture)
    with Sys_error details ->
      Error
        (Console_capture_failed
           { instance_name; capture_path = capture; details })
  in
  let close_capture_channel channel_opt =
    match channel_opt with
    | Some channel -> close_out_noerr channel
    | None -> ()
  in
  match connect_serial_socket socket endpoint 40 with
  | Error details ->
      close_socket ();
      Error (Serial_endpoint_unavailable { instance_name; endpoint; details })
  | Ok () -> (
      let capture_channel_result =
        match capture_path with
        | Some capture -> open_capture_channel capture
        | None -> Ok stdout
      in
      match capture_channel_result with
      | Error _ as error ->
          close_socket ();
          error
      | Ok capture_channel -> (
          let capture_channel_opt =
            match capture_path with
            | Some _ -> Some capture_channel
            | None -> None
          in
          let read_timeout_seconds =
            match timeout_seconds with
            | Some value when value > 0.0 -> Some value
            | _ -> None
          in
          let deadline =
            match read_timeout_seconds with
            | Some seconds -> Some (Unix.gettimeofday () +. seconds)
            | None -> None
          in
          let saved_termios =
            if read_stdin && Unix.isatty stdin_fd then (
              let term = Unix.tcgetattr stdin_fd in
              Unix.tcsetattr stdin_fd Unix.TCSAFLUSH
                { term with
                  Unix.c_echo = false;
                  Unix.c_icanon = false;
                  Unix.c_isig = false;
                  Unix.c_ixon = false;
                  Unix.c_vmin = 1;
                  Unix.c_vtime = 0;
                };
              Some term)
            else None
          in
          let restore_termios () =
            match saved_termios with
            | Some term -> Unix.tcsetattr stdin_fd Unix.TCSAFLUSH term
            | None -> ()
          in
          let saw_prefix = ref false in
          if read_stdin then
            Printf.printf "\r[console attached — ctrl-t q to detach]\n%!";
          try
            let rec loop read_stdin =
              let read_fds =
                if read_stdin then [ socket; stdin_fd ] else [ socket ]
              in
              let wait_timeout =
                match deadline with
                | None -> -1.0
                | Some deadline_time ->
                    let remaining = deadline_time -. Unix.gettimeofday () in
                    if remaining <= 0.0 then 0.0 else remaining
              in
              let ready, _, _ = Unix.select read_fds [] [] wait_timeout in
              if
                ready = []
                && match deadline with Some _ -> true | None -> false
              then
                raise
                  (Failure
                     (Printf.sprintf "console timeout reached after %.3fs"
                        (match read_timeout_seconds with
                        | Some seconds -> seconds
                        | None -> 0.0)));
              let read_stdin =
                if read_stdin && List.exists (( = ) stdin_fd) ready then
                  let buf = Bytes.create 4096 in
                  match Unix.read stdin_fd buf 0 (Bytes.length buf) with
                  | 0 ->
                      Unix.shutdown socket Unix.SHUTDOWN_SEND;
                      false
                  | n ->
                      if !saw_prefix then (
                        saw_prefix := false;
                        if Bytes.get buf 0 = 'q' || Bytes.get buf 0 = 'Q' then
                          raise Exit;
                        write_all socket (Bytes.make 1 '\x14') 0 1);
                      let flush_from = ref 0 in
                      let i = ref 0 in
                      while !i < n do
                        if Bytes.get buf !i = '\x14' then (
                          if !i + 1 < n then (
                            if
                              Bytes.get buf (!i + 1) = 'q'
                              || Bytes.get buf (!i + 1) = 'Q'
                            then (
                              write_all socket buf !flush_from
                                (!i - !flush_from);
                              raise Exit)
                            else
                              i := !i + 1)
                          else (
                            write_all socket buf !flush_from
                              (!i - !flush_from);
                            saw_prefix := true;
                            flush_from := n;
                            i := n))
                        else
                          i := !i + 1
                      done;
                      if !flush_from < n then
                        write_all socket buf !flush_from (n - !flush_from);
                      true
                else read_stdin
              in
              let socket_open =
                if List.exists (( = ) socket) ready then
                  match
                    read_and_forward socket stdout_fd capture_channel_opt
                  with
                  | `Eof -> false
                  | `Ok -> true
                else true
              in
              if socket_open then loop read_stdin
            in
            loop read_stdin;
            restore_termios ();
            close_capture_channel capture_channel_opt;
            close_socket ();
            Ok ()
          with
          | Exit ->
              restore_termios ();
              close_capture_channel capture_channel_opt;
              close_socket ();
              Printf.printf "\r\n[console detached]\n%!";
              Ok ()
          | Failure message when contains message "console timeout reached" ->
              restore_termios ();
              close_capture_channel capture_channel_opt;
              close_socket ();
              Error
                (Console_session_timed_out
                   {
                     instance_name;
                     timeout_seconds =
                       (match read_timeout_seconds with
                       | Some seconds -> seconds
                       | None -> 0.0);
                   })
          | Unix.Unix_error (error, _, _) ->
              restore_termios ();
              close_capture_channel capture_channel_opt;
              close_socket ();
              Error
                (Serial_endpoint_unavailable
                   {
                     instance_name;
                     endpoint;
                     details = Unix.error_message error;
                   })))

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
  | Vm_disk_overlay_prepare_failed { target; details } ->
      Printf.sprintf
        "VM launch failed for %s: unable to prepare writable overlay for \
         target-built disk: %s"
        target details
  | Seed_iso_generation_failed { target; details } ->
      Printf.sprintf
        "VM launch failed for %s: seed ISO generation failed: %s" target
        details
  | Pasta_missing { target } ->
      Printf.sprintf
        "VM launch failed for %s: passt binary not found on $PATH. Set \
         EPI_PASST_BIN or install the passt package to enable userspace \
         networking."
        target
  | Pasta_socket_unavailable { target; socket } ->
      Printf.sprintf
        "VM launch failed for %s: pasta failed to create vhost-user socket \
         at %s. Check that the pasta binary supports --vhost-user mode."
        target socket

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
  | Console_capture_failed { instance_name; capture_path; details } ->
      Printf.sprintf
        "Console capture setup failed for '%s' at %s: %s. Check capture file \
         path and permissions."
        instance_name capture_path details
  | Console_session_timed_out { instance_name; timeout_seconds } ->
      Printf.sprintf
        "Console session timed out for '%s' after %.3fs. Increase \
         EPI_CONSOLE_TIMEOUT_SECONDS or retry with interactive console."
        instance_name timeout_seconds
