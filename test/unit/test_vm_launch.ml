let contains text snippet =
  let tl = String.length text and sl = String.length snippet in
  if sl = 0 then true
  else
    let rec loop i =
      if i + sl > tl then false
      else if String.sub text i sl = snippet then true
      else loop (i + 1)
    in
    loop 0

let with_env key value f =
  let old = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match old with
      | Some v -> Unix.putenv key v
      | None -> Unix.putenv key "")
    f

let with_temp_dir prefix f =
  let base =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (prefix ^ string_of_int (Unix.getpid ()))
  in
  let rec find_free n =
    let candidate = if n = 0 then base else base ^ "-" ^ string_of_int n in
    if Sys.file_exists candidate then find_free (n + 1) else candidate
  in
  let dir = find_free 0 in
  Unix.mkdir dir 0o755;
  let rec remove_tree path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Sys.readdir path
        |> Array.iter (fun name -> remove_tree (Filename.concat path name));
        Unix.rmdir path)
      else Sys.remove path
  in
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () -> f dir)

let with_state_dir f =
  with_temp_dir "epi-vm-launch-test" (fun dir ->
      with_env "EPI_STATE_DIR" dir (fun () -> f dir))

let tests =
  [
    Alcotest.test_case "resize_disk returns error when qemu-img is absent"
      `Quick (fun () ->
        with_env "EPI_QEMU_IMG_BIN" "/nonexistent/qemu-img" (fun () ->
            match
              Vm_launch.resize_disk ~target:"test-target" ~path:"/tmp/fake.img"
                ~size:"1G"
            with
            | Error (Vm_launch.Vm_disk_resize_failed _) -> ()
            | Error _ -> Alcotest.fail "expected Vm_disk_resize_failed"
            | Ok () -> Alcotest.fail "expected error when qemu-img absent"));
    Alcotest.test_case "generate_user_data with no mounts produces no write_files"
      `Quick (fun () ->
        let data =
          Vm_launch.generate_user_data ~username:"alice" ~ssh_keys:[]
            ~user_exists:false ~host_uid:1000 ~mount_paths:[]
        in
        if contains data "write_files" then
          Alcotest.fail "expected no write_files when mount_paths is empty");
    Alcotest.test_case "generate_user_data with one mount produces one unit file"
      `Quick (fun () ->
        let data =
          Vm_launch.generate_user_data ~username:"alice" ~ssh_keys:[]
            ~user_exists:false ~host_uid:1000 ~mount_paths:[ "/home/alice/proj" ]
        in
        if not (contains data "write_files") then
          Alcotest.fail "expected write_files with one mount";
        if not (contains data "hostfs-0") then
          Alcotest.fail "expected hostfs-0 tag";
        if not (contains data "Where=/home/alice/proj") then
          Alcotest.fail "expected Where=/home/alice/proj";
        if not (contains data "Type=virtiofs") then
          Alcotest.fail "expected Type=virtiofs");
    Alcotest.test_case "generate_user_data with two mounts produces two unit files"
      `Quick (fun () ->
        let data =
          Vm_launch.generate_user_data ~username:"alice" ~ssh_keys:[]
            ~user_exists:false ~host_uid:1000
            ~mount_paths:[ "/home/alice/proj"; "/home/alice/secrets" ]
        in
        if not (contains data "hostfs-0") then
          Alcotest.fail "expected hostfs-0 tag";
        if not (contains data "hostfs-1") then
          Alcotest.fail "expected hostfs-1 tag";
        if not (contains data "Where=/home/alice/proj") then
          Alcotest.fail "expected Where=/home/alice/proj";
        if not (contains data "Where=/home/alice/secrets") then
          Alcotest.fail "expected Where=/home/alice/secrets");
    Alcotest.test_case
      "ensure_writable_disk skips resize when overlay already exists" `Quick
      (fun () ->
        with_state_dir (fun state_dir ->
            let instance_name = "test-skip-resize" in
            let instance_dir = Filename.concat state_dir instance_name in
            Unix.mkdir instance_dir 0o755;
            let overlay_path = Filename.concat instance_dir "disk.img" in
            let oc = open_out overlay_path in
            close_out oc;
            with_env "EPI_QEMU_IMG_BIN" "/nonexistent/qemu-img" (fun () ->
                let descriptor : Target.descriptor =
                  {
                    kernel = "/nix/store/fake/vmlinuz";
                    disk = "/nix/store/fake/disk.img";
                    initrd = None;
                    cmdline = Target.default_cmdline;
                    cpus = 1;
                    memory_mib = 1024;
                    configured_users = [];
                  }
                in
                match
                  Vm_launch.ensure_writable_disk ~instance_name
                    ~target:"test-target" ~disk_size:"40G" descriptor
                with
                | Ok returned_path ->
                    Alcotest.(check string)
                      "overlay path" overlay_path returned_path
                | Error _ ->
                    Alcotest.fail
                      "expected Ok when overlay already exists (resize \
                       should be skipped)")));
  ]
