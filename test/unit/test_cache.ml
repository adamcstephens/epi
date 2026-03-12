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

let with_env key value f =
  let old = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match old with Some v -> Unix.putenv key v | None -> Unix.putenv key "")
    f

let make_descriptor ~dir =
  let kernel = Filename.concat dir "vmlinuz" in
  let disk = Filename.concat dir "disk.img" in
  let oc = open_out kernel in
  output_string oc "kernel";
  close_out oc;
  let oc = open_out disk in
  output_string oc "disk";
  close_out oc;
  let descriptor : Target.descriptor =
    {
      kernel;
      disk;
      initrd = None;
      cmdline = Target.default_cmdline;
      cpus = 2;
      memory_mib = 1024;
      configured_users = [];
      hooks = { post_launch = []; pre_stop = [] };
    }
  in
  (descriptor, kernel, disk)

let resolver_call_count = ref 0

let tests =
  [
    Alcotest.test_case "cache write after resolve" `Quick (fun () ->
        with_temp_dir "epi-cache-unit" (fun dir ->
            let descriptor, _kernel, _disk = make_descriptor ~dir in
            let cache_dir = Filename.concat dir "cache" in
            Unix.mkdir cache_dir 0o755;
            let resolver_script = Filename.concat dir "resolver.sh" in
            let json =
              Yojson.Basic.pretty_to_string
                (Target.descriptor_to_json descriptor)
            in
            let oc = open_out resolver_script in
            Printf.fprintf oc "#!/usr/bin/env sh\nprintf '%s'\n" json;
            close_out oc;
            Unix.chmod resolver_script 0o755;
            with_env "EPI_CACHE_DIR" cache_dir (fun () ->
                with_env "EPI_TARGET_RESOLVER_CMD" resolver_script (fun () ->
                    match
                      Target.resolve_descriptor_cached ~rebuild:false
                        ".#test-cache"
                    with
                    | Error e -> Alcotest.fail e.details
                    | Ok (Target.Cached _) ->
                        Alcotest.fail "expected Resolved, got Cached"
                    | Ok (Target.Resolved d) ->
                        Alcotest.(check string)
                          "kernel" descriptor.kernel d.kernel;
                        let targets_dir = Filename.concat cache_dir "targets" in
                        let files = Sys.readdir targets_dir |> Array.to_list in
                        let has_descriptor =
                          List.exists
                            (fun name ->
                              let len = String.length name in
                              len > 11
                              && String.sub name (len - 11) 11 = ".descriptor")
                            files
                        in
                        Alcotest.(check bool)
                          "cache file written" true has_descriptor))));
    Alcotest.test_case "cache hit skips resolver" `Quick (fun () ->
        with_temp_dir "epi-cache-hit" (fun dir ->
            let descriptor, _kernel, _disk = make_descriptor ~dir in
            let cache_dir = Filename.concat dir "cache" in
            Unix.mkdir cache_dir 0o755;
            resolver_call_count := 0;
            let resolver_log = Filename.concat dir "resolver.log" in
            let resolver_script = Filename.concat dir "resolver.sh" in
            let json =
              Yojson.Basic.pretty_to_string
                (Target.descriptor_to_json descriptor)
            in
            let oc = open_out resolver_script in
            Printf.fprintf oc
              "#!/usr/bin/env sh\necho call >> '%s'\nprintf '%s'\n" resolver_log
              json;
            close_out oc;
            Unix.chmod resolver_script 0o755;
            with_env "EPI_CACHE_DIR" cache_dir (fun () ->
                with_env "EPI_TARGET_RESOLVER_CMD" resolver_script (fun () ->
                    (* First call: resolves and caches *)
                    let _ =
                      Target.resolve_descriptor_cached ~rebuild:false
                        ".#test-hit"
                    in
                    (* Second call: should hit cache *)
                    match
                      Target.resolve_descriptor_cached ~rebuild:false
                        ".#test-hit"
                    with
                    | Error e -> Alcotest.fail e.details
                    | Ok (Target.Resolved _) ->
                        Alcotest.fail "expected Cached on second call"
                    | Ok (Target.Cached d) ->
                        Alcotest.(check string)
                          "kernel" descriptor.kernel d.kernel;
                        let count =
                          if Sys.file_exists resolver_log then
                            In_channel.with_open_text resolver_log
                              In_channel.input_all
                            |> String.split_on_char '\n'
                            |> List.filter (fun l -> String.equal l "call")
                            |> List.length
                          else 0
                        in
                        Alcotest.(check int) "resolver called once" 1 count))));
    Alcotest.test_case "cache miss on missing paths triggers re-resolve" `Quick
      (fun () ->
        with_temp_dir "epi-cache-miss" (fun dir ->
            let descriptor, _kernel, _disk = make_descriptor ~dir in
            let cache_dir = Filename.concat dir "cache" in
            Unix.mkdir cache_dir 0o755;
            let resolver_log = Filename.concat dir "resolver.log" in
            let resolver_script = Filename.concat dir "resolver.sh" in
            let json =
              Yojson.Basic.pretty_to_string
                (Target.descriptor_to_json descriptor)
            in
            let oc = open_out resolver_script in
            Printf.fprintf oc
              "#!/usr/bin/env sh\necho call >> '%s'\nprintf '%s'\n" resolver_log
              json;
            close_out oc;
            Unix.chmod resolver_script 0o755;
            with_env "EPI_CACHE_DIR" cache_dir (fun () ->
                with_env "EPI_TARGET_RESOLVER_CMD" resolver_script (fun () ->
                    (* First call: resolves and caches *)
                    let _ =
                      Target.resolve_descriptor_cached ~rebuild:false
                        ".#test-miss"
                    in
                    (* Corrupt the cache to point to nonexistent paths *)
                    let targets_dir = Filename.concat cache_dir "targets" in
                    let files = Sys.readdir targets_dir |> Array.to_list in
                    List.iter
                      (fun name ->
                        let path = Filename.concat targets_dir name in
                        let json = Yojson.Basic.from_file path in
                        let corrupted =
                          match json with
                          | `Assoc fields ->
                              `Assoc
                                (List.map
                                   (fun (k, v) ->
                                     if String.equal k "disk" then
                                       (k, `String "/nonexistent")
                                     else (k, v))
                                   fields)
                          | other -> other
                        in
                        Yojson.Basic.to_file path corrupted)
                      files;
                    (* Second call: should re-resolve *)
                    match
                      Target.resolve_descriptor_cached ~rebuild:false
                        ".#test-miss"
                    with
                    | Error e -> Alcotest.fail e.details
                    | Ok (Target.Cached _) ->
                        Alcotest.fail "expected Resolved after cache corruption"
                    | Ok (Target.Resolved _) ->
                        let count =
                          if Sys.file_exists resolver_log then
                            In_channel.with_open_text resolver_log
                              In_channel.input_all
                            |> String.split_on_char '\n'
                            |> List.filter (fun l -> String.equal l "call")
                            |> List.length
                          else 0
                        in
                        Alcotest.(check int) "resolver called twice" 2 count))));
    Alcotest.test_case "--rebuild busts cache" `Quick (fun () ->
        with_temp_dir "epi-cache-rebuild" (fun dir ->
            let descriptor, _kernel, _disk = make_descriptor ~dir in
            let cache_dir = Filename.concat dir "cache" in
            Unix.mkdir cache_dir 0o755;
            let resolver_log = Filename.concat dir "resolver.log" in
            let resolver_script = Filename.concat dir "resolver.sh" in
            let json =
              Yojson.Basic.pretty_to_string
                (Target.descriptor_to_json descriptor)
            in
            let oc = open_out resolver_script in
            Printf.fprintf oc
              "#!/usr/bin/env sh\necho call >> '%s'\nprintf '%s'\n" resolver_log
              json;
            close_out oc;
            Unix.chmod resolver_script 0o755;
            with_env "EPI_CACHE_DIR" cache_dir (fun () ->
                with_env "EPI_TARGET_RESOLVER_CMD" resolver_script (fun () ->
                    (* First call: resolves and caches *)
                    let _ =
                      Target.resolve_descriptor_cached ~rebuild:false
                        ".#test-rebuild"
                    in
                    (* Second call with rebuild: should re-resolve *)
                    match
                      Target.resolve_descriptor_cached ~rebuild:true
                        ".#test-rebuild"
                    with
                    | Error e -> Alcotest.fail e.details
                    | Ok (Target.Cached _) ->
                        Alcotest.fail "expected Resolved after rebuild"
                    | Ok (Target.Resolved _) ->
                        let count =
                          if Sys.file_exists resolver_log then
                            In_channel.with_open_text resolver_log
                              In_channel.input_all
                            |> String.split_on_char '\n'
                            |> List.filter (fun l -> String.equal l "call")
                            |> List.length
                          else 0
                        in
                        Alcotest.(check int) "resolver called twice" 2 count))));
  ]
