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

let with_test_dirs f =
  with_temp_dir "epi-prov-int" (fun dir ->
    let state_dir = Filename.concat dir "state" in
    let cache_dir = Filename.concat dir "cache" in
    Unix.mkdir state_dir 0o755;
    Unix.mkdir cache_dir 0o755;
    with_env "EPI_STATE_DIR" state_dir (fun () ->
      with_env "EPI_CACHE_DIR" cache_dir (fun () ->
        f ~state_dir ~cache_dir)))

let make_descriptor dir =
  let kernel = Filename.concat dir "vmlinuz" in
  let disk = Filename.concat dir "disk.img" in
  let initrd = Filename.concat dir "initrd.img" in
  let write path content =
    let oc = open_out path in
    output_string oc content;
    close_out oc
  in
  write kernel "kernel";
  write disk "disk";
  write initrd "initrd";
  { Mock_modules.default_descriptor with
    kernel;
    disk;
    initrd = Some initrd;
  }

let tests =
  [
    Alcotest.test_case "successful provision writes state" `Quick (fun () ->
        with_test_dirs (fun ~state_dir ~cache_dir:_ ->
            with_temp_dir "epi-prov-desc" (fun dir ->
                let descriptor = make_descriptor dir in
                let runtime = { Mock_modules.default_runtime with
                  unit_id = "test-unit-123";
                  ssh_port = Some 12345;
                  ssh_key_path = "/tmp/test-key";
                } in
                let resolver = Mock_modules.make_mock_resolver
                  ~resolve:(fun _target -> Ok descriptor) () in
                let runner = Mock_modules.make_mock_runner
                  ~launch:(fun ~mount_paths:_ ~disk_size:_ ~instance_name:_ ~target:_ _desc ->
                    Ok runtime) () in
                match Vm_launch.provision ~resolver ~runner ~rebuild:false
                        ~mount_paths:[] ~disk_size:"40G" ~instance_name:"prov-ok"
                        ~target:".#prov-ok" () with
                | Error err ->
                    Alcotest.fail (Vm_launch.pp_provision_error err)
                | Ok result ->
                    Instance_store.set_provisioned ~instance_name:"prov-ok"
                      ~target:".#prov-ok" ~runtime:result;
                    Alcotest.(check bool) "unit_id non-empty" true
                      (String.length result.Instance_store.unit_id > 0);
                    Alcotest.(check bool) "ssh_port set" true
                      (result.Instance_store.ssh_port <> None);
                    let loaded = Instance_store.find_runtime "prov-ok" in
                    Alcotest.(check bool) "state persisted" true
                      (loaded <> None);
                    (match loaded with
                     | Some r ->
                         Alcotest.(check string) "unit_id matches"
                           result.unit_id r.unit_id
                     | None -> ());
                    let instance_dir = Filename.concat state_dir "prov-ok" in
                    Alcotest.(check bool) "instance dir exists" true
                      (Sys.file_exists instance_dir))));
    Alcotest.test_case "failed provision does not persist" `Quick (fun () ->
        with_test_dirs (fun ~state_dir:_ ~cache_dir:_ ->
            with_temp_dir "epi-prov-desc" (fun dir ->
                let descriptor = make_descriptor dir in
                let resolver = Mock_modules.make_mock_resolver
                  ~resolve:(fun _target -> Ok descriptor) () in
                let runner = Mock_modules.make_mock_runner
                  ~launch:(fun ~mount_paths:_ ~disk_size:_ ~instance_name:_ ~target _desc ->
                    Error (Vm_launch.Vm_launch_failed { target; exit_code = 12; details = "mock launch failed" })) () in
                match Vm_launch.provision ~resolver ~runner ~rebuild:false
                        ~mount_paths:[] ~disk_size:"40G" ~instance_name:"prov-fail"
                        ~target:".#prov-fail" () with
                | Ok _ ->
                    Alcotest.fail "expected provision to fail"
                | Error _ ->
                    let loaded = Instance_store.find_runtime "prov-fail" in
                    Alcotest.(check bool) "no runtime persisted" true
                      (loaded = None))));
    Alcotest.test_case "cached descriptor reuse" `Quick (fun () ->
        with_test_dirs (fun ~state_dir:_ ~cache_dir ->
            with_temp_dir "epi-prov-desc" (fun dir ->
                let descriptor = make_descriptor dir in
                let (increment, get_count) = Mock_modules.call_counter () in
                let resolver = Mock_modules.make_mock_resolver
                  ~resolve_cached:(Some (fun ~rebuild target ->
                    let _ = target in
                    let cache_path =
                      let hash = Digest.string target |> Digest.to_hex in
                      let target_cache = Filename.concat cache_dir "targets" in
                      if not (Sys.file_exists target_cache) then Unix.mkdir target_cache 0o755;
                      Filename.concat target_cache (hash ^ ".descriptor")
                    in
                    if rebuild && Sys.file_exists cache_path then Sys.remove cache_path;
                    if Sys.file_exists cache_path then
                      Ok (Target.Cached descriptor)
                    else (
                      increment ();
                      Yojson.Basic.to_file cache_path (Target.descriptor_to_json descriptor);
                      Ok (Target.Resolved descriptor)))) () in
                let runner = Mock_modules.make_mock_runner () in
                (* First provision *)
                (match Vm_launch.provision ~resolver ~runner ~rebuild:false
                         ~mount_paths:[] ~disk_size:"40G" ~instance_name:"cache-1"
                         ~target:".#cache-reuse" () with
                 | Error err -> Alcotest.fail (Vm_launch.pp_provision_error err)
                 | Ok _ -> ());
                (* Second provision — should use cache *)
                (match Vm_launch.provision ~resolver ~runner ~rebuild:false
                         ~mount_paths:[] ~disk_size:"40G" ~instance_name:"cache-2"
                         ~target:".#cache-reuse" () with
                 | Error err -> Alcotest.fail (Vm_launch.pp_provision_error err)
                 | Ok _ -> ());
                Alcotest.(check int) "resolver called once" 1 (get_count ());
                let targets_dir = Filename.concat cache_dir "targets" in
                let files = Sys.readdir targets_dir |> Array.to_list in
                Alcotest.(check bool) "cache file exists" true
                  (List.exists (fun n ->
                     let len = String.length n in
                     len > 11 && String.sub n (len - 11) 11 = ".descriptor") files))));
    Alcotest.test_case "--rebuild forces re-eval" `Quick (fun () ->
        with_test_dirs (fun ~state_dir:_ ~cache_dir ->
            with_temp_dir "epi-prov-desc" (fun dir ->
                let descriptor = make_descriptor dir in
                let (increment, get_count) = Mock_modules.call_counter () in
                let resolver = Mock_modules.make_mock_resolver
                  ~resolve_cached:(Some (fun ~rebuild target ->
                    let cache_path =
                      let hash = Digest.string target |> Digest.to_hex in
                      let target_cache = Filename.concat cache_dir "targets" in
                      if not (Sys.file_exists target_cache) then Unix.mkdir target_cache 0o755;
                      Filename.concat target_cache (hash ^ ".descriptor")
                    in
                    if rebuild && Sys.file_exists cache_path then Sys.remove cache_path;
                    if Sys.file_exists cache_path then
                      Ok (Target.Cached descriptor)
                    else (
                      increment ();
                      Yojson.Basic.to_file cache_path (Target.descriptor_to_json descriptor);
                      Ok (Target.Resolved descriptor)))) () in
                let runner = Mock_modules.make_mock_runner () in
                (* First provision *)
                (match Vm_launch.provision ~resolver ~runner ~rebuild:false
                         ~mount_paths:[] ~disk_size:"40G" ~instance_name:"rebuild-1"
                         ~target:".#rebuild-test" () with
                 | Error err -> Alcotest.fail (Vm_launch.pp_provision_error err)
                 | Ok _ -> ());
                (* Second provision with rebuild *)
                (match Vm_launch.provision ~resolver ~runner ~rebuild:true
                         ~mount_paths:[] ~disk_size:"40G" ~instance_name:"rebuild-2"
                         ~target:".#rebuild-test" () with
                 | Error err -> Alcotest.fail (Vm_launch.pp_provision_error err)
                 | Ok _ -> ());
                Alcotest.(check int) "resolver called twice" 2 (get_count ()))));
  ]
