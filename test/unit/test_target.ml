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

let check_ok msg = function
  | Ok _ -> ()
  | Error (`Msg e) -> Alcotest.fail (msg ^ ": " ^ e)

let check_error msg = function
  | Error _ -> ()
  | Ok _ -> Alcotest.fail (msg ^ ": expected error")

let tests =
  [
    Alcotest.test_case "of_string accepts valid targets" `Quick (fun () ->
        check_ok "simple" (Target.of_string ".#dev");
        check_ok "github" (Target.of_string "github:org/repo#config");
        check_ok "path" (Target.of_string "/path/to/flake#name"));
    Alcotest.test_case "of_string rejects missing separator" `Quick (fun () ->
        check_error "no hash" (Target.of_string "no-hash-here");
        check_error "dot only" (Target.of_string "."));
    Alcotest.test_case "of_string rejects empty parts" `Quick (fun () ->
        check_error "empty config" (Target.of_string ".#");
        check_error "empty flake" (Target.of_string "#config");
        check_error "both empty" (Target.of_string "#"));
    Alcotest.test_case "to_string round-trips" `Quick (fun () ->
        let target = ".#dev" in
        match Target.of_string target with
        | Ok t ->
            Alcotest.(check string) "round-trip" target (Target.to_string t)
        | Error (`Msg e) -> Alcotest.fail e);
    Alcotest.test_case "is_nix_store_path detects store paths" `Quick (fun () ->
        Alcotest.(check bool)
          "store path" true
          (Target.is_nix_store_path "/nix/store/abc-pkg/vmlinuz");
        Alcotest.(check bool)
          "non-store path" false
          (Target.is_nix_store_path "/tmp/vmlinuz");
        Alcotest.(check bool) "empty" false (Target.is_nix_store_path ""));
    Alcotest.test_case "store_root_of_path extracts store root" `Quick
      (fun () ->
        Alcotest.(check (option string))
          "with subpath" (Some "/nix/store/abc-pkg")
          (Target.store_root_of_path "/nix/store/abc-pkg/vmlinuz");
        Alcotest.(check (option string))
          "root only" (Some "/nix/store/abc-pkg")
          (Target.store_root_of_path "/nix/store/abc-pkg");
        Alcotest.(check (option string))
          "non-store" None
          (Target.store_root_of_path "/tmp/file"));
    Alcotest.test_case "split_target splits on hash" `Quick (fun () ->
        Alcotest.(check (option (pair string string)))
          "valid"
          (Some (".", "dev"))
          (Target.split_target ".#dev");
        Alcotest.(check (option (pair string string)))
          "github"
          (Some ("github:org/repo", "config"))
          (Target.split_target "github:org/repo#config");
        Alcotest.(check (option (pair string string)))
          "no hash" None
          (Target.split_target "no-hash");
        Alcotest.(check (option (pair string string)))
          "empty flake" None
          (Target.split_target "#config");
        Alcotest.(check (option (pair string string)))
          "empty config" None (Target.split_target ".#"));
    Alcotest.test_case "canonicalize_target translates shorthand" `Quick
      (fun () ->
        Alcotest.(check string)
          "dot shorthand" ".#nixosConfigurations.manual-test"
          (Target.canonicalize_target ".#manual-test");
        Alcotest.(check string)
          "github shorthand" "github:org/repo#nixosConfigurations.config"
          (Target.canonicalize_target "github:org/repo#config");
        Alcotest.(check string)
          "path shorthand" "/path/to/flake#nixosConfigurations.name"
          (Target.canonicalize_target "/path/to/flake#name"));
    Alcotest.test_case "canonicalize_target skips already-canonical" `Quick
      (fun () ->
        Alcotest.(check string)
          "already canonical" ".#nixosConfigurations.manual-test"
          (Target.canonicalize_target ".#nixosConfigurations.manual-test"));
    Alcotest.test_case "canonicalize_target handles edge cases" `Quick
      (fun () ->
        Alcotest.(check string)
          "no hash" "no-hash"
          (Target.canonicalize_target "no-hash");
        Alcotest.(check string)
          "empty config" ".#"
          (Target.canonicalize_target ".#");
        Alcotest.(check string)
          "empty flake" "#config"
          (Target.canonicalize_target "#config"));
    Alcotest.test_case "resolve_descriptor canonicalizes target for resolver"
      `Quick (fun () ->
        with_temp_dir "epi-target-canon" (fun dir ->
            let log = Filename.concat dir "target.log" in
            let kernel = Filename.concat dir "vmlinuz" in
            let disk = Filename.concat dir "disk.img" in
            let oc = open_out kernel in
            output_string oc "k";
            close_out oc;
            let oc = open_out disk in
            output_string oc "d";
            close_out oc;
            let resolver = Filename.concat dir "resolver.sh" in
            let oc = open_out resolver in
            Printf.fprintf oc
              "#!/usr/bin/env sh\n\
               echo \"$EPI_TARGET\" > %s\n\
               printf '{\"kernel\": \"%s\", \"disk\": \"%s\", \"cpus\": 1, \
               \"memory_mib\": 512}'\n"
              log kernel disk;
            close_out oc;
            Unix.chmod resolver 0o755;
            let cache_dir = Filename.concat dir "cache" in
            Unix.mkdir cache_dir 0o755;
            with_env "EPI_CACHE_DIR" cache_dir (fun () ->
                with_env "EPI_TARGET_RESOLVER_CMD" resolver (fun () ->
                    match Target.resolve_descriptor ".#myvm" with
                    | Error e -> Alcotest.fail e.details
                    | Ok _ ->
                        let ic = open_in log in
                        let received = input_line ic in
                        close_in ic;
                        Alcotest.(check string)
                          "canonicalized" ".#nixosConfigurations.myvm" received))));
    Alcotest.test_case "resolve_descriptor returns error for failing resolver"
      `Quick (fun () ->
        with_temp_dir "epi-target-fail" (fun dir ->
            let resolver = Filename.concat dir "resolver.sh" in
            let oc = open_out resolver in
            output_string oc
              "#!/usr/bin/env sh\necho \"not found\" >&2\nexit 1\n";
            close_out oc;
            Unix.chmod resolver 0o755;
            let cache_dir = Filename.concat dir "cache" in
            Unix.mkdir cache_dir 0o755;
            with_env "EPI_CACHE_DIR" cache_dir (fun () ->
                with_env "EPI_TARGET_RESOLVER_CMD" resolver (fun () ->
                    match Target.resolve_descriptor ".#nonexistent" with
                    | Ok _ -> Alcotest.fail "expected error"
                    | Error e ->
                        Alcotest.(check string)
                          "target is canonicalized in error"
                          ".#nixosConfigurations.nonexistent" e.target))));
    Alcotest.test_case "descriptor_of_json uses defaults for missing fields"
      `Quick (fun () ->
        let json =
          Yojson.Basic.from_string {|{"kernel": "/k", "disk": "/d"}|}
        in
        let d = Target.descriptor_of_json json in
        Alcotest.(check string) "kernel" "/k" d.kernel;
        Alcotest.(check string) "disk" "/d" d.disk;
        Alcotest.(check (option string)) "initrd" None d.initrd;
        Alcotest.(check string) "cmdline" Target.default_cmdline d.cmdline;
        Alcotest.(check int) "cpus" 1 d.cpus;
        Alcotest.(check int) "memory_mib" 1024 d.memory_mib;
        Alcotest.(check (list string)) "configured_users" [] d.configured_users);
    Alcotest.test_case "descriptor_of_json parses all fields" `Quick (fun () ->
        let json =
          Yojson.Basic.from_string
            {|{"kernel": "/k", "disk": "/d", "initrd": "/i",
             "cmdline": "console=ttyS0 root=/dev/vda1",
             "cpus": 4, "memory_mib": 2048,
             "configuredUsers": ["root", "admin"]}|}
        in
        let d = Target.descriptor_of_json json in
        Alcotest.(check string) "kernel" "/k" d.kernel;
        Alcotest.(check string) "disk" "/d" d.disk;
        Alcotest.(check (option string)) "initrd" (Some "/i") d.initrd;
        Alcotest.(check string)
          "cmdline" "console=ttyS0 root=/dev/vda1" d.cmdline;
        Alcotest.(check int) "cpus" 4 d.cpus;
        Alcotest.(check int) "memory_mib" 2048 d.memory_mib;
        Alcotest.(check (list string))
          "configured_users" [ "root"; "admin" ] d.configured_users);
    Alcotest.test_case "descriptor_of_json parses hooks from attrsets" `Quick
      (fun () ->
        let json =
          Yojson.Basic.from_string
            {|{"kernel": "/k", "disk": "/d",
             "hooks": {
               "post-launch": {"01-setup.sh": "/nix/store/setup", "00-first.sh": "/nix/store/first"},
               "pre-stop": {"cleanup.sh": "/nix/store/cleanup"},
               "guest-init": {"init.sh": "/nix/store/init"}
             }}|}
        in
        let d = Target.descriptor_of_json json in
        Alcotest.(check (list string))
          "post-launch sorted by key"
          [ "/nix/store/first"; "/nix/store/setup" ]
          d.hooks.post_launch;
        Alcotest.(check (list string))
          "pre-stop" [ "/nix/store/cleanup" ] d.hooks.pre_stop);
    Alcotest.test_case
      "descriptor_of_json parses hooks from arrays (cache format)" `Quick
      (fun () ->
        let json =
          Yojson.Basic.from_string
            {|{"kernel": "/k", "disk": "/d",
             "hooks": {
               "post-launch": ["/nix/store/first", "/nix/store/setup"],
               "pre-stop": ["/nix/store/cleanup"]
             }}|}
        in
        let d = Target.descriptor_of_json json in
        Alcotest.(check (list string))
          "post-launch"
          [ "/nix/store/first"; "/nix/store/setup" ]
          d.hooks.post_launch;
        Alcotest.(check (list string))
          "pre-stop" [ "/nix/store/cleanup" ] d.hooks.pre_stop);
    Alcotest.test_case "descriptor_of_json defaults hooks to empty" `Quick
      (fun () ->
        let json =
          Yojson.Basic.from_string {|{"kernel": "/k", "disk": "/d"}|}
        in
        let d = Target.descriptor_of_json json in
        Alcotest.(check (list string)) "post-launch" [] d.hooks.post_launch;
        Alcotest.(check (list string)) "pre-stop" [] d.hooks.pre_stop);
    Alcotest.test_case "descriptor_to_json omits hooks when empty" `Quick
      (fun () ->
        let d : Target.descriptor =
          {
            kernel = "/k";
            disk = "/d";
            initrd = None;
            cmdline = Target.default_cmdline;
            cpus = 1;
            memory_mib = 1024;
            configured_users = [];
            hooks = { post_launch = []; pre_stop = [] };
          }
        in
        let json = Target.descriptor_to_json d in
        let open Yojson.Basic.Util in
        Alcotest.(check bool)
          "no hooks field" true
          (json |> member "hooks" = `Null));
    Alcotest.test_case "descriptor_to_json includes hooks when present" `Quick
      (fun () ->
        let d : Target.descriptor =
          {
            kernel = "/k";
            disk = "/d";
            initrd = None;
            cmdline = Target.default_cmdline;
            cpus = 1;
            memory_mib = 1024;
            configured_users = [];
            hooks = { post_launch = [ "/nix/store/setup" ]; pre_stop = [] };
          }
        in
        let json = Target.descriptor_to_json d in
        let open Yojson.Basic.Util in
        let hooks = json |> member "hooks" in
        Alcotest.(check bool) "hooks present" true (hooks <> `Null);
        let pl =
          hooks |> member "post-launch" |> to_list
          |> List.filter_map to_string_option
        in
        Alcotest.(check (list string)) "post-launch" [ "/nix/store/setup" ] pl;
        Alcotest.(check bool)
          "pre-stop omitted" true
          (hooks |> member "pre-stop" = `Null));
    Alcotest.test_case "validate_descriptor_coherence rejects mixed store paths"
      `Quick (fun () ->
        let d : Target.descriptor =
          {
            kernel = "/nix/store/abc/vmlinuz";
            disk = "/tmp/disk.img";
            initrd = None;
            cmdline = Target.default_cmdline;
            cpus = 1;
            memory_mib = 1024;
            configured_users = [];
            hooks = { post_launch = []; pre_stop = [] };
          }
        in
        match Target.validate_descriptor_coherence d with
        | Error msg ->
            if not (String.length msg > 0) then
              Alcotest.fail "expected non-empty error message"
        | Ok () -> Alcotest.fail "expected coherence error for mixed paths");
    Alcotest.test_case "validate_descriptor_coherence accepts all store paths"
      `Quick (fun () ->
        let d : Target.descriptor =
          {
            kernel = "/nix/store/abc/vmlinuz";
            disk = "/nix/store/def/disk.img";
            initrd = Some "/nix/store/ghi/initrd";
            cmdline = Target.default_cmdline;
            cpus = 1;
            memory_mib = 1024;
            configured_users = [];
            hooks = { post_launch = []; pre_stop = [] };
          }
        in
        match Target.validate_descriptor_coherence d with
        | Ok () -> ()
        | Error msg -> Alcotest.fail msg);
  ]
