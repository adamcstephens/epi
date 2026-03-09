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
      owner_unit_id : string;
    }
  | Vm_disk_lock_held_unknown of { target : string; disk : string }
  | Vm_exited_immediately of { target : string; details : string }
  | Vm_disk_overlay_prepare_failed of { target : string; details : string }
  | Seed_iso_generation_failed of { target : string; details : string }
  | Passt_missing of { target : string }
  | Passt_failed of { target : string; details : string }
  | Virtiofsd_missing of { target : string }
  | Virtiofsd_failed of { target : string; details : string }
  | Mount_path_not_a_directory of { target : string; path : string }
  | Vm_disk_resize_failed of { target : string; details : string }
  | Systemd_session_unavailable of { target : string; details : string }

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
          { Instance_store.unit_id = owner_unit_id; _ } ) ->
        Vm_disk_lock_held_by_instance
          { target; disk = descriptor.Target.disk; owner_instance; owner_unit_id }
    | None -> Vm_disk_lock_held_unknown { target; disk = descriptor.Target.disk }
  else
    Vm_launch_failed
      {
        target;
        exit_code = status;
        details = (if stderr = "" then "<no stderr>" else stderr);
      }

let qemu_img_bin () =
  match Sys.getenv_opt "EPI_QEMU_IMG_BIN" with
  | Some path -> path
  | None -> "qemu-img"

let find_qemu_img () =
  let bin = qemu_img_bin () in
  let result =
    Process.run ~prog:"sh" ~args:[ "-c"; "command -v " ^ bin ] ()
  in
  if result.status = 0 then Some bin else None

let resize_disk ~target ~path ~size =
  match find_qemu_img () with
  | None ->
      Error
        (Vm_disk_resize_failed
           {
             target;
             details =
               "qemu-img not found on $PATH. Set EPI_QEMU_IMG_BIN or install \
                qemu-utils.";
           })
  | Some bin ->
      let result = Process.run ~prog:bin ~args:[ "resize"; path; size ] () in
      if result.status <> 0 then
        Error
          (Vm_disk_resize_failed
             {
               target;
               details =
                 (if result.stderr = "" then "<no stderr>" else result.stderr);
             })
      else Ok ()

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

let ensure_writable_disk ~instance_name ~target ~disk_size (descriptor : Target.descriptor) =
  if Target.is_nix_store_path descriptor.disk then
    let overlay_path =
      Instance_store.instance_path instance_name "disk.img"
    in
    if Sys.file_exists overlay_path then Ok overlay_path
    else (
      Instance_store.ensure_instance_dir instance_name;
      try
        copy_file ~source:descriptor.disk ~destination:overlay_path;
        match resize_disk ~target ~path:overlay_path ~size:disk_size with
        | Error _ as error -> error
        | Ok () -> Ok overlay_path
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

let generate_user_data ~username ~ssh_keys ~user_exists ~host_uid =
  let buf = Buffer.create 256 in
  Buffer.add_string buf "#cloud-config\ndisable_root: false\nusers:\n";
  Buffer.add_string buf (Printf.sprintf "  - name: %s\n" username);
  if not user_exists then (
    Buffer.add_string buf (Printf.sprintf "    uid: %d\n" host_uid);
    Buffer.add_string buf "    groups: wheel\n";
    Buffer.add_string buf "    sudo: ALL=(ALL) NOPASSWD:ALL\n";
    Buffer.add_string buf "    shell: /run/current-system/sw/bin/bash\n");
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
  let id = Printf.sprintf "%s-%d" instance_name (int_of_float (Unix.time ())) in
  Printf.sprintf "instance-id: %s\nlocal-hostname: %s\n" id instance_name

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

let virtiofsd_bin () =
  match Sys.getenv_opt "EPI_VIRTIOFSD_BIN" with
  | Some path -> path
  | None -> "virtiofsd"

let check_virtiofsd () =
  let bin = virtiofsd_bin () in
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

let generate_seed_iso ~instance_name ~instance_dir ~username ~ssh_keys ~user_exists ~host_uid ~mount_paths =
  if not (check_genisoimage ()) then Error Genisoimage_missing
  else
    let iso_path =
      Filename.concat instance_dir "cidata.iso"
    in
    let staging_dir =
      Filename.concat instance_dir "cidata"
    in
    (if not (Sys.file_exists staging_dir) then
       Unix.mkdir staging_dir 0o755);
    let user_data_path = Filename.concat staging_dir "user-data" in
    let meta_data_path = Filename.concat staging_dir "meta-data" in
    let user_data = generate_user_data ~username ~ssh_keys ~user_exists ~host_uid in
    let meta_data = generate_meta_data ~instance_name in
    let write path content =
      let channel = open_out path in
      output_string channel content;
      close_out channel
    in
    write user_data_path user_data;
    write meta_data_path meta_data;
    let epi_mounts_path =
      match mount_paths with
      | [] -> None
      | paths ->
          let p = Filename.concat staging_dir "epi-mounts" in
          write p (String.concat "\n" paths ^ "\n");
          Some p
    in
    let iso_files =
      [ user_data_path; meta_data_path ]
      @ Option.to_list epi_mounts_path
    in
    let result =
      Process.run ~prog:(genisoimage_bin ())
        ~args:
          ([ "-output"; iso_path; "-volid"; "cidata"; "-joliet"; "-rock" ]
           @ iso_files)
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

let generate_ssh_key ~instance_name =
  let key_path =
    Instance_store.instance_path instance_name "id_ed25519"
  in
  Instance_store.ensure_instance_dir instance_name;
  if Sys.file_exists key_path then Unix.unlink key_path;
  let pub_path = key_path ^ ".pub" in
  if Sys.file_exists pub_path then Unix.unlink pub_path;
  let result =
    Process.run ~prog:"ssh-keygen"
      ~args:[ "-t"; "ed25519"; "-f"; key_path; "-N"; ""; "-C"; "epi-generated" ]
      ()
  in
  if result.status <> 0 then
    failwith
      (Printf.sprintf "ssh-keygen failed (exit=%d): %s" result.status
         result.stderr)
  else
    let pub_content = Target.read_file_if_exists pub_path |> String.trim in
    (key_path, pub_content)

let is_session_unavailable_error stderr =
  let lowered = Target.lowercase stderr in
  Target.contains lowered "no such file or directory"
  && Target.contains lowered "user"
  || Target.contains lowered "failed to get d-bus connection"
  || Target.contains lowered "no user session"

let launch_detached ~generate_ssh_key:do_generate_ssh_key ~mount_paths ~disk_size ~instance_name ~target (descriptor : Target.descriptor) =
  let cloud_hypervisor_bin =
    match Sys.getenv_opt "EPI_CLOUD_HYPERVISOR_BIN" with
    | Some path -> path
    | None -> "cloud-hypervisor"
  in
  Instance_store.ensure_instance_dir instance_name;
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
  let instance_dir = Instance_store.instance_dir instance_name in
  let ssh_keys = read_ssh_public_keys () in
  let generated_key =
    if do_generate_ssh_key then (
      let key_path, pub_content = generate_ssh_key ~instance_name in
      Printf.printf "vm: generated SSH key %s\n%!" key_path;
      Some (key_path, pub_content))
    else None
  in
  let ssh_keys =
    match generated_key with
    | Some (_, pub_content) -> ssh_keys @ [ pub_content ]
    | None -> ssh_keys
  in
  let ssh_key_path =
    match generated_key with Some (path, _) -> Some path | None -> None
  in
  let host_uid = Unix.getuid () in
  let user_exists = List.mem username descriptor.configured_users in
  let passt_sock =
    Filename.concat instance_dir "passt.sock"
  in
  let ssh_port = alloc_free_port () in
  let non_dir_mount = List.find_opt (fun p -> not (Sys.is_directory p)) mount_paths in
  if not (check_passt ()) then Error (Passt_missing { target })
  else if Option.is_some non_dir_mount then
    Error (Mount_path_not_a_directory { target; path = Option.get non_dir_mount })
  else if mount_paths <> [] && not (check_virtiofsd ()) then
    Error (Virtiofsd_missing { target })
  else
  match generate_seed_iso ~instance_name ~instance_dir ~username ~ssh_keys ~user_exists ~host_uid ~mount_paths with
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
  match ensure_writable_disk ~instance_name ~target ~disk_size descriptor with
  | Error _ as error -> error
  | Ok launch_disk -> (
      let unit_id = Process.generate_unit_id () in
      let escaped = Process.escape_unit_name instance_name in
      let slice = Printf.sprintf "epi-%s-%s.slice" escaped unit_id in
      if Sys.file_exists passt_sock then Unix.unlink passt_sock;
      let passt_repair_sock = passt_sock ^ ".repair" in
      if Sys.file_exists passt_repair_sock then Unix.unlink passt_repair_sock;
      let passt_stdout_log =
        Filename.concat instance_dir "passt.stdout.log"
      in
      let passt_stderr_log =
        Filename.concat instance_dir "passt.stderr.log"
      in
      let passt_unit = Printf.sprintf "epi-%s-%s-passt" escaped unit_id in
      let passt_result =
        Process.run_helper ~unit_name:passt_unit ~slice
          ~stdout_path:passt_stdout_log ~stderr_path:passt_stderr_log
          ~prog:(passt_bin ())
          ~args:[ "--foreground"; "--vhost-user"; "--socket"; passt_sock;
                  "-t"; Printf.sprintf "%d:22" ssh_port ]
          ()
      in
      if passt_result.status <> 0 then
        if is_session_unavailable_error passt_result.stderr then
          Error (Systemd_session_unavailable { target; details = passt_result.stderr })
        else
          Error (Passt_failed { target; details = passt_result.stderr })
      else if not (wait_for_passt_socket passt_sock 2000) then
        let stdout = Target.read_file_if_exists passt_stdout_log |> String.trim in
        let stderr = Target.read_file_if_exists passt_stderr_log |> String.trim in
        let details =
          match (stdout, stderr) with
          | "", "" -> "passt produced no output"
          | "", s | s, "" -> s
          | out, err -> out ^ "\n" ^ err
        in
        Error (Passt_failed { target; details })
      else
      let start_virtiofsd i path =
        let sock = Filename.concat instance_dir (Printf.sprintf "virtiofsd-%d.sock" i) in
        if Sys.file_exists sock then Unix.unlink sock;
        let stdout_log = Filename.concat instance_dir (Printf.sprintf "virtiofsd-%d.stdout.log" i) in
        let stderr_log = Filename.concat instance_dir (Printf.sprintf "virtiofsd-%d.stderr.log" i) in
        let virtiofsd_unit = Printf.sprintf "epi-%s-%s-virtiofsd-%d" escaped unit_id i in
        let result =
          Process.run_helper ~unit_name:virtiofsd_unit ~slice
            ~stdout_path:stdout_log ~stderr_path:stderr_log
            ~prog:(virtiofsd_bin ())
            ~args:[ "--socket-path"; sock; "--shared-dir"; path ]
            ()
        in
        if result.status <> 0 then
          Error (Virtiofsd_failed { target; details = result.stderr })
        else if not (wait_for_passt_socket sock 2000) then
          let stdout = Target.read_file_if_exists stdout_log |> String.trim in
          let stderr = Target.read_file_if_exists stderr_log |> String.trim in
          let details =
            match (stdout, stderr) with
            | "", "" -> "virtiofsd produced no output"
            | "", s | s, "" -> s
            | out, err -> out ^ "\n" ^ err
          in
          Error (Virtiofsd_failed { target; details })
        else Ok sock
      in
      let virtiofsd_result =
        let rec loop acc i = function
          | [] -> Ok (List.rev acc)
          | path :: rest -> (
              match start_virtiofsd i path with
              | Error _ as e -> e
              | Ok sock -> loop (sock :: acc) (i + 1) rest)
        in
        loop [] 0 mount_paths
      in
      match virtiofsd_result with
      | Error _ as error -> error
      | Ok virtiofsd_sockets ->
      Instance_store.save_mounts instance_name mount_paths;
      let disk_arg = "path=" ^ launch_disk in
      let seed_disk_arg = "path=" ^ seed_iso_path ^ ",readonly=on" in
      let net_arg =
        "vhost_user=true,socket=" ^ passt_sock ^ ",vhost_mode=client"
      in
      let fs_args =
        match virtiofsd_sockets with
        | [] -> []
        | sockets ->
            let values =
              List.mapi (fun i sock ->
                  Printf.sprintf "tag=hostfs-%d,socket=%s" i sock)
                sockets
            in
            "--fs" :: values
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
        @ fs_args
      in
      let args =
        match descriptor.initrd with
        | Some initrd -> base_args @ [ "--initramfs"; initrd ]
        | None -> base_args
      in
      let exec_stop_post =
        Printf.sprintf "%s --user stop %s" Process.systemctl_bin slice
      in
      let vm_unit = Printf.sprintf "epi-%s-%s-vm" escaped unit_id in
      let vm_result =
        Process.run_service ~unit_name:vm_unit ~slice
          ~stdout_path:launch_stdout ~stderr_path:launch_stderr
          ~exec_stop_post
          ~prog:cloud_hypervisor_bin ~args ()
      in
      if vm_result.status <> 0 then
        if is_session_unavailable_error vm_result.stderr then
          Error (Systemd_session_unavailable { target; details = vm_result.stderr })
        else
          let stderr = Target.read_file_if_exists launch_stderr |> String.trim in
          if lock_conflict stderr then
            Error (classify_launch_failure ~target ~descriptor ~status:vm_result.status ~stderr)
          else
            Error
              (Vm_launch_failed
                 {
                   target;
                   exit_code = vm_result.status;
                   details = (if vm_result.stderr = "" then "<no stderr>" else vm_result.stderr);
                 })
      else
        (* systemd-run returns 0 after creating the unit, but the VM process
           may exit immediately (e.g. exec failure, lock conflict). Wait
           briefly for the process to settle, then verify it is still alive. *)
        let vm_service = vm_unit ^ ".service" in
        let _ = Unix.select [] [] [] 0.15 in
        if not (Process.unit_is_active vm_service) then
          let stderr = Target.read_file_if_exists launch_stderr |> String.trim in
          if lock_conflict stderr then
            Error (classify_launch_failure ~target ~descriptor ~status:1 ~stderr)
          else
            Error
              (Vm_launch_failed
                 {
                   target;
                   exit_code = 1;
                   details = (if stderr = "" then "VM exited immediately after start" else stderr);
                 })
        else
          Ok
            {
              Instance_store.unit_id;
              serial_socket;
              disk = launch_disk;
              ssh_port = Some ssh_port;
              ssh_key_path;
            })

let provision ~rebuild ~generate_ssh_key ~mount_paths ~disk_size ~instance_name ~target =
  Printf.printf "vm: resolving target=%s\n%!" target;
  let descriptor =
    match Target.resolve_descriptor_cached ~rebuild target with
    | Error { details; exit_code; _ } ->
        Error (Target_resolution_failed { target; details; exit_code })
    | Ok (Target.Cached descriptor) ->
        Printf.printf "vm: using cached descriptor\n%!";
        Ok descriptor
    | Ok (Target.Resolved descriptor) ->
        Printf.printf "vm: evaluated target, building artifacts\n%!";
        Ok descriptor
  in
  match descriptor with
  | Error _ as error -> error
  | Ok descriptor -> (
      match Target.validate_descriptor ~target descriptor with
      | Error details ->
          Error (Descriptor_validation_failed { target; details })
      | Ok () ->
          Printf.printf "vm: starting VM instance=%s\n%!" instance_name;
          launch_detached ~generate_ssh_key ~mount_paths ~disk_size ~instance_name ~target descriptor)

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
  | Vm_disk_lock_held_by_instance { target; disk; owner_instance; owner_unit_id } ->
      Printf.sprintf
        "VM launch failed for %s: another running VM already holds disk lock \
         %s (owner=%s unit_id=%s). Stop that instance and retry."
        target disk owner_instance owner_unit_id
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
  | Virtiofsd_missing { target } ->
      Printf.sprintf
        "VM launch failed for %s: virtiofsd binary not found on $PATH. Set \
         EPI_VIRTIOFSD_BIN or install the virtiofsd package to enable virtiofs \
         host directory sharing."
        target
  | Virtiofsd_failed { target; details } ->
      Printf.sprintf
        "VM launch failed for %s: virtiofsd failed to start: %s" target details
  | Mount_path_not_a_directory { target; path } ->
      Printf.sprintf
        "VM launch failed for %s: --mount path is not a directory: %s \
         (virtiofsd only supports directory sharing)"
        target path
  | Vm_disk_resize_failed { target; details } ->
      Printf.sprintf
        "VM launch failed for %s: disk resize failed: %s" target details
  | Systemd_session_unavailable { target; details } ->
      Printf.sprintf
        "VM launch failed for %s: systemd user session unavailable: %s\n\
         Ensure your user session is active. You may need to run: loginctl enable-linger %s"
        target details
        (match Sys.getenv_opt "USER" with Some u -> u | None -> "$USER")
