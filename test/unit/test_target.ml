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
    Alcotest.test_case "parse_key_value_output parses basic pairs" `Quick
      (fun () ->
        let pairs = Target.parse_key_value_output "kernel=/path\ndisk=/disk\n" in
        Alcotest.(check (option string)) "kernel"
          (Some "/path") (List.assoc_opt "kernel" pairs);
        Alcotest.(check (option string)) "disk"
          (Some "/disk") (List.assoc_opt "disk" pairs));
    Alcotest.test_case "parse_key_value_output handles multi-equals values"
      `Quick (fun () ->
        let pairs = Target.parse_key_value_output "cmdline=a=b=c\n" in
        Alcotest.(check (option string)) "cmdline"
          (Some "a=b=c") (List.assoc_opt "cmdline" pairs));
    Alcotest.test_case "parse_key_value_output skips empty values" `Quick
      (fun () ->
        let pairs = Target.parse_key_value_output "empty=\nvalid=yes\n" in
        Alcotest.(check (option string)) "empty"
          None (List.assoc_opt "empty" pairs);
        Alcotest.(check (option string)) "valid"
          (Some "yes") (List.assoc_opt "valid" pairs));
    Alcotest.test_case "parse_key_value_output skips blank lines" `Quick
      (fun () ->
        let pairs = Target.parse_key_value_output "\n\nkey=val\n\n" in
        Alcotest.(check int) "count" 1 (List.length pairs));
    Alcotest.test_case "is_nix_store_path detects store paths" `Quick (fun () ->
        Alcotest.(check bool) "store path" true
          (Target.is_nix_store_path "/nix/store/abc-pkg/vmlinuz");
        Alcotest.(check bool) "non-store path" false
          (Target.is_nix_store_path "/tmp/vmlinuz");
        Alcotest.(check bool) "empty" false
          (Target.is_nix_store_path ""));
    Alcotest.test_case "store_root_of_path extracts store root" `Quick (fun () ->
        Alcotest.(check (option string)) "with subpath"
          (Some "/nix/store/abc-pkg")
          (Target.store_root_of_path "/nix/store/abc-pkg/vmlinuz");
        Alcotest.(check (option string)) "root only"
          (Some "/nix/store/abc-pkg")
          (Target.store_root_of_path "/nix/store/abc-pkg");
        Alcotest.(check (option string)) "non-store"
          None
          (Target.store_root_of_path "/tmp/file"));
    Alcotest.test_case "split_target splits on hash" `Quick (fun () ->
        Alcotest.(check (option (pair string string))) "valid"
          (Some (".", "dev"))
          (Target.split_target ".#dev");
        Alcotest.(check (option (pair string string))) "github"
          (Some ("github:org/repo", "config"))
          (Target.split_target "github:org/repo#config");
        Alcotest.(check (option (pair string string))) "no hash"
          None
          (Target.split_target "no-hash");
        Alcotest.(check (option (pair string string))) "empty flake"
          None
          (Target.split_target "#config");
        Alcotest.(check (option (pair string string))) "empty config"
          None
          (Target.split_target ".#"));
    Alcotest.test_case "descriptor_of_output uses defaults for missing fields"
      `Quick (fun () ->
        let d = Target.descriptor_of_output "kernel=/k\ndisk=/d\n" in
        Alcotest.(check string) "kernel" "/k" d.kernel;
        Alcotest.(check string) "disk" "/d" d.disk;
        Alcotest.(check (option string)) "initrd" None d.initrd;
        Alcotest.(check string) "cmdline" Target.default_cmdline d.cmdline;
        Alcotest.(check int) "cpus" 1 d.cpus;
        Alcotest.(check int) "memory_mib" 1024 d.memory_mib;
        Alcotest.(check (list string)) "configured_users" [] d.configured_users);
    Alcotest.test_case "descriptor_of_output parses all fields" `Quick (fun () ->
        let d = Target.descriptor_of_output
          "kernel=/k\n\
           disk=/d\n\
           initrd=/i\n\
           cmdline=console=ttyS0 root=/dev/vda1\n\
           cpus=4\n\
           memory_mib=2048\n\
           configured_users=root,admin\n"
        in
        Alcotest.(check string) "kernel" "/k" d.kernel;
        Alcotest.(check string) "disk" "/d" d.disk;
        Alcotest.(check (option string)) "initrd" (Some "/i") d.initrd;
        Alcotest.(check string) "cmdline" "console=ttyS0 root=/dev/vda1" d.cmdline;
        Alcotest.(check int) "cpus" 4 d.cpus;
        Alcotest.(check int) "memory_mib" 2048 d.memory_mib;
        Alcotest.(check (list string)) "configured_users"
          ["root"; "admin"] d.configured_users);
    Alcotest.test_case "find_json_string extracts values" `Quick (fun () ->
        let json = {|{"kernel": "/path/to/kernel", "disk": "/path/to/disk"}|} in
        Alcotest.(check (option string)) "kernel"
          (Some "/path/to/kernel")
          (Target.find_json_string ~key:"kernel" json);
        Alcotest.(check (option string)) "disk"
          (Some "/path/to/disk")
          (Target.find_json_string ~key:"disk" json);
        Alcotest.(check (option string)) "missing"
          None
          (Target.find_json_string ~key:"nonexistent" json));
    Alcotest.test_case "find_json_int extracts integers" `Quick (fun () ->
        let json = {|{"cpus": 4, "memory_mib": 2048}|} in
        Alcotest.(check (option int)) "cpus"
          (Some 4) (Target.find_json_int ~key:"cpus" json);
        Alcotest.(check (option int)) "memory_mib"
          (Some 2048) (Target.find_json_int ~key:"memory_mib" json);
        Alcotest.(check (option int)) "missing"
          None (Target.find_json_int ~key:"nonexistent" json));
    Alcotest.test_case "validate_descriptor_coherence rejects mixed store paths"
      `Quick (fun () ->
        let d : Target.descriptor = {
          kernel = "/nix/store/abc/vmlinuz";
          disk = "/tmp/disk.img";
          initrd = None;
          cmdline = Target.default_cmdline;
          cpus = 1;
          memory_mib = 1024;
          configured_users = [];
        } in
        match Target.validate_descriptor_coherence d with
        | Error msg ->
            if not (String.length msg > 0) then
              Alcotest.fail "expected non-empty error message"
        | Ok () -> Alcotest.fail "expected coherence error for mixed paths");
    Alcotest.test_case "validate_descriptor_coherence accepts all store paths"
      `Quick (fun () ->
        let d : Target.descriptor = {
          kernel = "/nix/store/abc/vmlinuz";
          disk = "/nix/store/def/disk.img";
          initrd = Some "/nix/store/ghi/initrd";
          cmdline = Target.default_cmdline;
          cpus = 1;
          memory_mib = 1024;
          configured_users = [];
        } in
        match Target.validate_descriptor_coherence d with
        | Ok () -> ()
        | Error msg -> Alcotest.fail msg);
  ]
