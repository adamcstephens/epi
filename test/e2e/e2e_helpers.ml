let unique_name prefix =
  let suffix = Printf.sprintf "%06x" (Random.bits () land 0xFFFFFF) in
  Printf.sprintf "%s-%s" prefix suffix

let with_cleanup ~instance_name runtime f =
  Fun.protect
    ~finally:(fun () ->
      ignore (Epi.stop_instance ~instance_name runtime);
      Epi.Instance_store.remove instance_name)
    (fun () -> f ())

let provision_and_wait ?(rebuild = false) ~instance_name ~target ~mount_paths () =
  match
    Epi.Vm_launch.provision ~rebuild ~mount_paths ~disk_size:"40G"
      ~instance_name ~target
  with
  | Error err ->
    Alcotest.fail (Epi.Vm_launch.pp_provision_error err)
  | Ok runtime ->
    Epi.Instance_store.set_provisioned ~instance_name ~target ~runtime;
    let ssh_port =
      match runtime.Epi.Instance_store.ssh_port with
      | Some p -> p
      | None -> Alcotest.fail "no SSH port in runtime"
    in
    (match
       Epi.Vm_launch.wait_for_ssh ~ssh_port
         ~ssh_key_path:runtime.Epi.Instance_store.ssh_key_path
         ~timeout_seconds:120
     with
     | Ok () -> runtime
     | Error err ->
       Alcotest.fail (Epi.Vm_launch.pp_provision_error err))

let ssh_exec runtime cmd =
  let ssh_port =
    match runtime.Epi.Instance_store.ssh_port with
    | Some p -> p
    | None -> Alcotest.fail "no SSH port in runtime"
  in
  let username =
    match Sys.getenv_opt "USER" with Some u -> u | None -> "user"
  in
  let port_str = string_of_int ssh_port in
  let target = username ^ "@127.0.0.1" in
  let result =
    Epi.Process.run ~prog:"ssh"
      ~args:
        ([
           "-T"; "-p"; port_str;
           "-i"; runtime.Epi.Instance_store.ssh_key_path;
           "-o"; "StrictHostKeyChecking=no";
           "-o"; "UserKnownHostsFile=/dev/null";
           "-o"; "BatchMode=yes";
           target;
         ]
        @ cmd)
      ()
  in
  if result.Epi.Process.status <> 0 then
    Alcotest.fail
      (Printf.sprintf "SSH command failed (exit=%d): %s" result.status
         result.stderr);
  result.stdout

let check_disk_grew runtime =
  let out = ssh_exec runtime [ "df"; "--output=size"; "/" ] in
  let lines = String.split_on_char '\n' out in
  let size_line =
    List.find_opt (fun l -> String.trim l <> "" && String.trim l <> "1K-blocks") lines
  in
  match size_line with
  | None -> Alcotest.fail "could not parse df output"
  | Some line ->
    let size_kb = int_of_string (String.trim line) in
    (* 40G disk should yield at least 30G usable *)
    let min_kb = 30 * 1024 * 1024 in
    if size_kb < min_kb then
      Alcotest.fail
        (Printf.sprintf "root filesystem too small: %d KB (expected >= %d KB)"
           size_kb min_kb)

let restart_instance ~instance_name ~target runtime =
  ignore (Epi.stop_instance ~instance_name runtime);
  Epi.Instance_store.clear_runtime instance_name;
  let mount_paths = Epi.Instance_store.load_mounts instance_name in
  provision_and_wait ~instance_name ~target ~mount_paths ()
