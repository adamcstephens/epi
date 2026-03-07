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
  | Passt_missing of { target : string }
  | Passt_failed of { target : string; details : string }

let lock_conflict stderr =
  let lowered = Target.lowercase stderr in
  Target.contains lowered "locked"
  || Target.contains lowered "lock conflict"
  || Target.contains lowered "resource temporarily unavailable"
  || Target.contains lowered "already in use"

let classify_launch_failure ~target ~descriptor ~status ~stderr =
  if lock_conflict stderr then
    match Instance_store.find_running_owner_by_disk descriptor.Target.disk with
    | Some
        ( owner_instance,
          { Instance_store.pid = owner_pid; _ } ) ->
        Vm_disk_lock_held_by_instance
          { target; disk = descriptor.Target.disk; owner_instance; owner_pid }
    | None -> Vm_disk_lock_held_unknown { target; disk = descriptor.Target.disk }
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

let ensure_writable_disk ~instance_name ~target (descriptor : Target.descriptor) =
  if Target.is_nix_store_path descriptor.disk then
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
              let content = Target.read_file_if_exists path |> String.trim in
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
  Buffer.add_string buf "    shell: /run/current-system/sw/bin/bash\n";
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

let wait_for_passt_socket socket_path max_wait_ms =
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

let alloc_free_port () =
  let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close sock)
    (fun () ->
      Unix.bind sock (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
      match Unix.getsockname sock with
      | Unix.ADDR_INET (_, port) -> port
      | _ -> failwith "alloc_free_port: unexpected socket address")

let launch_detached ~instance_name ~target (descriptor : Target.descriptor) =
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
  let passt_sock =
    Filename.concat runtime_dir (instance_name ^ ".passt.sock")
  in
  let ssh_port = alloc_free_port () in
  if not (check_passt ()) then Error (Passt_missing { target })
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
      if Sys.file_exists passt_sock then Unix.unlink passt_sock;
      let passt_repair_sock = passt_sock ^ ".repair" in
      if Sys.file_exists passt_repair_sock then Unix.unlink passt_repair_sock;
      let passt_stdout_log =
        Filename.concat runtime_dir (instance_name ^ ".passt.stdout.log")
      in
      let passt_stderr_log =
        Filename.concat runtime_dir (instance_name ^ ".passt.stderr.log")
      in
      let passt_proc =
        Process.run_detached ~prog:(passt_bin ())
          ~args:[ "--vhost-user"; "--socket"; passt_sock;
                  "-t"; Printf.sprintf "%d:22" ssh_port ]
          ~stdout_path:passt_stdout_log
          ~stderr_path:passt_stderr_log
          ()
      in
      if not (wait_for_passt_socket passt_sock 2000) then
        let stdout = Target.read_file_if_exists passt_stdout_log |> String.trim in
        let stderr = Target.read_file_if_exists passt_stderr_log |> String.trim in
        let details =
          match (stdout, stderr) with
          | "", "" -> "passt produced no output"
          | "", s | s, "" -> s
          | out, err -> out ^ "\n" ^ err
        in
        let _ = Unix.waitpid [ Unix.WNOHANG ] passt_proc.pid in
        Error (Passt_failed { target; details })
      else
      let disk_arg = "path=" ^ launch_disk in
      let seed_disk_arg = "path=" ^ seed_iso_path ^ ",readonly=on" in
      let net_arg =
        "vhost_user=true,socket=" ^ passt_sock ^ ",vhost_mode=client"
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
            passt_pid = Some passt_proc.pid;
            ssh_port = Some ssh_port;
          }
      else
        let stderr = Target.read_file_if_exists launch_stderr |> String.trim in
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

let provision ~rebuild ~instance_name ~target =
  Printf.printf "up: resolving target=%s\n%!" target;
  let descriptor =
    match Target.resolve_descriptor_cached ~rebuild target with
    | Error { details; exit_code; _ } ->
        Error (Target_resolution_failed { target; details; exit_code })
    | Ok (Target.Cached descriptor) ->
        Printf.printf "up: using cached descriptor\n%!";
        Ok descriptor
    | Ok (Target.Resolved descriptor) ->
        Printf.printf "up: evaluated target, building artifacts\n%!";
        Ok descriptor
  in
  match descriptor with
  | Error _ as error -> error
  | Ok descriptor -> (
      match Target.validate_descriptor ~target descriptor with
      | Error details ->
          Error (Descriptor_validation_failed { target; details })
      | Ok () ->
          Printf.printf "up: starting VM instance=%s\n%!" instance_name;
          launch_detached ~instance_name ~target descriptor)

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
  | Passt_missing { target } ->
      Printf.sprintf
        "VM launch failed for %s: passt binary not found on $PATH. Set \
         EPI_PASST_BIN or install the passt package to enable userspace \
         networking."
        target
  | Passt_failed { target; details } ->
      Printf.sprintf "VM launch failed for %s: passt failed to start: %s"
        target details
