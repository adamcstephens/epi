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
        (try Unix.rmdir path with Unix.Unix_error _ -> ()))
      else (try Sys.remove path with Sys_error _ -> ())
  in
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () -> f dir)

let with_env key value f =
  let old = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match old with
      | Some v -> Unix.putenv key v
      | None -> Unix.putenv key "")
    f

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

let with_mock_env dir f =
  let kernel = Filename.concat dir "vmlinuz" in
  let disk = Filename.concat dir "disk.img" in
  let initrd = Filename.concat dir "initrd.img" in
  write_file kernel "kernel";
  write_file disk "disk";
  write_file initrd "initrd";
  let resolver = Filename.concat dir "resolver.sh" in
  write_file resolver
    ("#!/usr/bin/env sh\n\
      if [ \"$EPI_TARGET\" = \".#fail-resolve\" ]; then\n\
     \  echo \"resolver exploded\" >&2\n\
     \  exit 21\n\
      fi\n\
      SAFE_TARGET=$(echo \"$EPI_TARGET\" | tr '/:' '__')\n\
      TARGET_DISK=\"" ^ dir ^ "/disk-${SAFE_TARGET}.img\"\n\
      cp -n \"" ^ disk ^ "\" \"$TARGET_DISK\" 2>/dev/null || true\n\
      printf '{\"kernel\": \"" ^ kernel ^ "\", \"disk\": \"'\"$TARGET_DISK\"'\", \"initrd\": \"" ^ initrd
   ^ "\", \"cpus\": 2, \"memory_mib\": 1536}'\n");
  let cloud_hypervisor = Filename.concat dir "cloud-hypervisor.sh" in
  write_file cloud_hypervisor
    ("#!/usr/bin/env sh\n\
      if [ \"$EPI_FORCE_LAUNCH_FAIL\" = \"1\" ]; then\n\
     \  echo \"mock launch failed\" >&2\n\
     \  exit 12\n\
      fi\n\
      exec sleep 30\n");
  let genisoimage = Filename.concat dir "genisoimage.sh" in
  write_file genisoimage
    "#!/usr/bin/env sh\n\
     OUTPUT=\"\"\n\
     while [ $# -gt 0 ]; do\n\
    \  case \"$1\" in\n\
    \    -output) OUTPUT=\"$2\"; shift 2 ;;\n\
    \    *) shift ;;\n\
    \  esac\n\
     done\n\
     if [ -n \"$OUTPUT\" ]; then echo mock > \"$OUTPUT\"; fi\n\
     exit 0\n";
  let passt = Filename.concat dir "passt.sh" in
  write_file passt
    "#!/usr/bin/env sh\n\
     prev=\"\"\n\
     for arg in \"$@\"; do\n\
    \  if [ \"$prev\" = \"--socket\" ]; then\n\
    \    touch \"$arg\"\n\
    \  fi\n\
    \  prev=\"$arg\"\n\
     done\n\
     exec sleep 30\n";
  List.iter (fun p -> Unix.chmod p 0o755) [resolver; cloud_hypervisor; genisoimage; passt];
  let cache_dir = Filename.concat dir "cache" in
  Unix.mkdir cache_dir 0o755;
  let state_dir = Filename.concat dir "state" in
  Unix.mkdir state_dir 0o755;
  let ssh_dir = Filename.concat dir "ssh" in
  Unix.mkdir ssh_dir 0o755;
  write_file (Filename.concat ssh_dir "id_test.pub") "ssh-ed25519 AAAA testkey";
  with_env "EPI_TARGET_RESOLVER_CMD" resolver (fun () ->
    with_env "EPI_CLOUD_HYPERVISOR_BIN" cloud_hypervisor (fun () ->
      with_env "EPI_GENISOIMAGE_BIN" genisoimage (fun () ->
        with_env "EPI_PASST_BIN" passt (fun () ->
          with_env "EPI_CACHE_DIR" cache_dir (fun () ->
            with_env "EPI_STATE_DIR" state_dir (fun () ->
              with_env "EPI_SSH_DIR" ssh_dir (fun () ->
                f ~state_dir ~cache_dir)))))))

let stop_instance instance_name =
  match Instance_store.find_runtime instance_name with
  | Some runtime ->
      let unit_id = runtime.Instance_store.unit_id in
      (match Instance_store.vm_unit_name ~instance_name ~unit_id with
       | Ok vm_unit -> ignore (Process.stop_unit vm_unit)
       | Error _ -> ());
      (match Instance_store.slice_name ~instance_name ~unit_id with
       | Ok slice -> ignore (Process.stop_unit slice)
       | Error _ -> ())
  | None -> ()

let tests =
  [
    Alcotest.test_case "successful provision writes state" `Quick (fun () ->
        with_temp_dir "epi-prov-int" (fun dir ->
            with_mock_env dir (fun ~state_dir ~cache_dir:_ ->
                match Vm_launch.provision ~rebuild:false ~mount_paths:[]
                        ~disk_size:"40G" ~instance_name:"prov-ok" ~target:".#prov-ok" with
                | Error err ->
                    Alcotest.fail (Vm_launch.pp_provision_error err)
                | Ok runtime ->
                    Instance_store.set_provisioned ~instance_name:"prov-ok"
                      ~target:".#prov-ok" ~runtime;
                    Fun.protect
                      ~finally:(fun () -> stop_instance "prov-ok")
                      (fun () ->
                        Alcotest.(check bool) "unit_id non-empty" true
                          (String.length runtime.Instance_store.unit_id > 0);
                        Alcotest.(check bool) "ssh_port set" true
                          (runtime.Instance_store.ssh_port <> None);
                        let loaded = Instance_store.find_runtime "prov-ok" in
                        Alcotest.(check bool) "state persisted" true
                          (loaded <> None);
                        match loaded with
                        | Some r ->
                            Alcotest.(check string) "unit_id matches"
                              runtime.unit_id r.unit_id
                        | None -> ());
                    let instance_dir = Filename.concat state_dir "prov-ok" in
                    Alcotest.(check bool) "instance dir exists" true
                      (Sys.file_exists instance_dir))));
    Alcotest.test_case "failed provision does not persist" `Quick (fun () ->
        with_temp_dir "epi-prov-fail" (fun dir ->
            with_mock_env dir (fun ~state_dir:_ ~cache_dir:_ ->
                with_env "EPI_FORCE_LAUNCH_FAIL" "1" (fun () ->
                  match Vm_launch.provision ~rebuild:false ~mount_paths:[]
                          ~disk_size:"40G" ~instance_name:"prov-fail" ~target:".#prov-fail" with
                  | Ok runtime ->
                      stop_instance "prov-fail";
                      ignore runtime;
                      Alcotest.fail "expected provision to fail"
                  | Error _ ->
                      let loaded = Instance_store.find_runtime "prov-fail" in
                      Alcotest.(check bool) "no runtime persisted" true
                        (loaded = None)))));
    Alcotest.test_case "cached descriptor reuse" `Quick (fun () ->
        with_temp_dir "epi-prov-cache" (fun dir ->
            with_mock_env dir (fun ~state_dir:_ ~cache_dir ->
                let resolver_log = Filename.concat dir "resolver.log" in
                let counting_resolver = Filename.concat dir "counting-resolver.sh" in
                let original_resolver = Sys.getenv "EPI_TARGET_RESOLVER_CMD" in
                write_file counting_resolver
                  ("#!/usr/bin/env sh\necho call >> '" ^ resolver_log ^ "'\nexec '" ^ original_resolver ^ "'\n");
                Unix.chmod counting_resolver 0o755;
                with_env "EPI_TARGET_RESOLVER_CMD" counting_resolver (fun () ->
                  (* First provision *)
                  (match Vm_launch.provision ~rebuild:false ~mount_paths:[]
                           ~disk_size:"40G" ~instance_name:"cache-1" ~target:".#cache-reuse" with
                   | Error err -> Alcotest.fail (Vm_launch.pp_provision_error err)
                   | Ok runtime ->
                       Instance_store.set_provisioned ~instance_name:"cache-1"
                         ~target:".#cache-reuse" ~runtime;
                       stop_instance "cache-1");
                  (* Second provision — should use cache *)
                  (match Vm_launch.provision ~rebuild:false ~mount_paths:[]
                           ~disk_size:"40G" ~instance_name:"cache-2" ~target:".#cache-reuse" with
                   | Error err -> Alcotest.fail (Vm_launch.pp_provision_error err)
                   | Ok runtime ->
                       Instance_store.set_provisioned ~instance_name:"cache-2"
                         ~target:".#cache-reuse" ~runtime;
                       stop_instance "cache-2");
                  let count =
                    if Sys.file_exists resolver_log then
                      In_channel.with_open_text resolver_log In_channel.input_all
                      |> String.split_on_char '\n'
                      |> List.filter (fun l -> String.equal l "call")
                      |> List.length
                    else 0
                  in
                  Alcotest.(check int) "resolver called once" 1 count;
                  let targets_dir = Filename.concat cache_dir "targets" in
                  let files = Sys.readdir targets_dir |> Array.to_list in
                  Alcotest.(check bool) "cache file exists" true
                    (List.exists (fun n ->
                       let len = String.length n in
                       len > 11 && String.sub n (len - 11) 11 = ".descriptor") files)))));
    Alcotest.test_case "--rebuild forces re-eval" `Quick (fun () ->
        with_temp_dir "epi-prov-rebuild" (fun dir ->
            with_mock_env dir (fun ~state_dir:_ ~cache_dir:_ ->
                let resolver_log = Filename.concat dir "resolver.log" in
                let counting_resolver = Filename.concat dir "counting-resolver.sh" in
                let original_resolver = Sys.getenv "EPI_TARGET_RESOLVER_CMD" in
                write_file counting_resolver
                  ("#!/usr/bin/env sh\necho call >> '" ^ resolver_log ^ "'\nexec '" ^ original_resolver ^ "'\n");
                Unix.chmod counting_resolver 0o755;
                with_env "EPI_TARGET_RESOLVER_CMD" counting_resolver (fun () ->
                  (* First provision *)
                  (match Vm_launch.provision ~rebuild:false ~mount_paths:[]
                           ~disk_size:"40G" ~instance_name:"rebuild-1" ~target:".#rebuild-test" with
                   | Error err -> Alcotest.fail (Vm_launch.pp_provision_error err)
                   | Ok runtime ->
                       Instance_store.set_provisioned ~instance_name:"rebuild-1"
                         ~target:".#rebuild-test" ~runtime;
                       stop_instance "rebuild-1");
                  (* Second provision with rebuild *)
                  (match Vm_launch.provision ~rebuild:true ~mount_paths:[]
                           ~disk_size:"40G" ~instance_name:"rebuild-2" ~target:".#rebuild-test" with
                   | Error err -> Alcotest.fail (Vm_launch.pp_provision_error err)
                   | Ok runtime ->
                       Instance_store.set_provisioned ~instance_name:"rebuild-2"
                         ~target:".#rebuild-test" ~runtime;
                       stop_instance "rebuild-2");
                  let count =
                    if Sys.file_exists resolver_log then
                      In_channel.with_open_text resolver_log In_channel.input_all
                      |> String.split_on_char '\n'
                      |> List.filter (fun l -> String.equal l "call")
                      |> List.length
                    else 0
                  in
                  Alcotest.(check int) "resolver called twice" 2 count))));
  ]
