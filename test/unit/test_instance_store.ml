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
  with_temp_dir "epi-store-test" (fun dir ->
      let old_env = Sys.getenv_opt "EPI_STATE_DIR" in
      Unix.putenv "EPI_STATE_DIR" dir;
      Fun.protect
        ~finally:(fun () ->
          match old_env with
          | Some v -> Unix.putenv "EPI_STATE_DIR" v
          | None ->
              (* No portable unsetenv in OCaml Unix, set to unlikely value *)
              Unix.putenv "EPI_STATE_DIR" dir)
        (fun () -> f dir))

let tests =
  [
    Alcotest.test_case "save and load runtime round-trips" `Quick (fun () ->
        with_state_dir (fun _dir ->
            let runtime : Instance_store.runtime =
              {
                unit_id = "abcd1234";
                serial_socket = "/tmp/test.sock";
                disk = "/tmp/test.img";
                ssh_port = Some 2222;
                ssh_key_path = "/tmp/test_key";
              }
            in
            Instance_store.set_provisioned ~instance_name:"roundtrip"
              ~target:".#test" ~runtime;
            match Instance_store.find_runtime "roundtrip" with
            | Some r ->
                Alcotest.(check string) "unit_id" "abcd1234" r.unit_id;
                Alcotest.(check string)
                  "serial_socket" "/tmp/test.sock" r.serial_socket;
                Alcotest.(check string) "disk" "/tmp/test.img" r.disk;
                Alcotest.(check (option int)) "ssh_port" (Some 2222) r.ssh_port;
                Alcotest.(check string)
                  "ssh_key_path" "/tmp/test_key" r.ssh_key_path
            | None -> Alcotest.fail "expected runtime to be found"));
    Alcotest.test_case "save and load target round-trips" `Quick (fun () ->
        with_state_dir (fun _dir ->
            Instance_store.set ~instance_name:"target-rt" ~target:".#myvm";
            match Instance_store.find "target-rt" with
            | Some target -> Alcotest.(check string) "target" ".#myvm" target
            | None -> Alcotest.fail "expected target to be found"));
    Alcotest.test_case "list with empty dir returns empty" `Quick (fun () ->
        with_state_dir (fun _dir ->
            let entries = Instance_store.list () in
            Alcotest.(check int) "count" 0 (List.length entries)));
    Alcotest.test_case "list returns multiple instances sorted" `Quick
      (fun () ->
        with_state_dir (fun _dir ->
            Instance_store.set ~instance_name:"beta" ~target:".#beta";
            Instance_store.set ~instance_name:"alpha" ~target:".#alpha";
            Instance_store.set ~instance_name:"gamma" ~target:".#gamma";
            let entries = Instance_store.list () in
            let names = List.map fst entries in
            Alcotest.(check (list string))
              "sorted"
              [ "alpha"; "beta"; "gamma" ]
              names));
    Alcotest.test_case "clear_runtime removes runtime but keeps entry" `Quick
      (fun () ->
        with_state_dir (fun _dir ->
            let runtime : Instance_store.runtime =
              {
                unit_id = "clear0001";
                serial_socket = "/tmp/s.sock";
                disk = "/tmp/d.img";
                ssh_port = None;
                ssh_key_path = "/tmp/clear_key";
              }
            in
            Instance_store.set_provisioned ~instance_name:"clear-rt"
              ~target:".#test" ~runtime;
            Instance_store.clear_runtime "clear-rt";
            (match Instance_store.find_runtime "clear-rt" with
            | None -> ()
            | Some _ -> Alcotest.fail "expected runtime to be cleared");
            match Instance_store.find "clear-rt" with
            | Some _ -> ()
            | None -> Alcotest.fail "expected entry to remain after clear"));
    Alcotest.test_case "remove deletes entire instance entry" `Quick (fun () ->
        with_state_dir (fun _dir ->
            Instance_store.set ~instance_name:"remove-me" ~target:".#test";
            Instance_store.remove "remove-me";
            match Instance_store.find "remove-me" with
            | None -> ()
            | Some _ -> Alcotest.fail "expected entry to be removed"));
    Alcotest.test_case "runtime with ssh_port as None round-trips" `Quick
      (fun () ->
        with_state_dir (fun _dir ->
            let runtime : Instance_store.runtime =
              {
                unit_id = "none0001";
                serial_socket = "/tmp/s.sock";
                disk = "/tmp/d.img";
                ssh_port = None;
                ssh_key_path = "/tmp/none_key";
              }
            in
            Instance_store.set_provisioned ~instance_name:"none-opts"
              ~target:".#test" ~runtime;
            match Instance_store.find_runtime "none-opts" with
            | Some r ->
                Alcotest.(check (option int)) "ssh_port" None r.ssh_port;
                Alcotest.(check string)
                  "ssh_key_path" "/tmp/none_key" r.ssh_key_path
            | None -> Alcotest.fail "expected runtime to be found"));
    Alcotest.test_case "set_launching writes target and partial runtime" `Quick
      (fun () ->
        with_state_dir (fun _dir ->
            Instance_store.set_launching ~instance_name:"launch-test"
              ~target:".#dev" ~unit_id:"launch0001";
            (match Instance_store.find "launch-test" with
            | Some target -> Alcotest.(check string) "target" ".#dev" target
            | None -> Alcotest.fail "expected target after set_launching");
            match Instance_store.find_runtime "launch-test" with
            | Some r ->
                Alcotest.(check string) "unit_id" "launch0001" r.unit_id;
                Alcotest.(check string) "serial_socket" "" r.serial_socket;
                Alcotest.(check string) "disk" "" r.disk;
                Alcotest.(check (option int)) "ssh_port" None r.ssh_port;
                Alcotest.(check string) "ssh_key_path" "" r.ssh_key_path
            | None -> Alcotest.fail "expected partial runtime after set_launching"));
    Alcotest.test_case "set_provisioned over partial runtime produces complete state"
      `Quick (fun () ->
        with_state_dir (fun _dir ->
            Instance_store.set_launching ~instance_name:"upgrade-test"
              ~target:".#dev" ~unit_id:"upgrade0001";
            let runtime : Instance_store.runtime =
              {
                unit_id = "upgrade0001";
                serial_socket = "/tmp/serial.sock";
                disk = "/tmp/disk.img";
                ssh_port = Some 2222;
                ssh_key_path = "/tmp/id_ed25519";
              }
            in
            Instance_store.set_provisioned ~instance_name:"upgrade-test"
              ~target:".#dev" ~runtime;
            (match Instance_store.find "upgrade-test" with
            | Some target -> Alcotest.(check string) "target" ".#dev" target
            | None -> Alcotest.fail "expected target after set_provisioned");
            match Instance_store.find_runtime "upgrade-test" with
            | Some r ->
                Alcotest.(check string) "unit_id" "upgrade0001" r.unit_id;
                Alcotest.(check string)
                  "serial_socket" "/tmp/serial.sock" r.serial_socket;
                Alcotest.(check string) "disk" "/tmp/disk.img" r.disk;
                Alcotest.(check (option int)) "ssh_port" (Some 2222) r.ssh_port;
                Alcotest.(check string)
                  "ssh_key_path" "/tmp/id_ed25519" r.ssh_key_path
            | None -> Alcotest.fail "expected complete runtime after set_provisioned"));
    Alcotest.test_case "partial runtime visible in list" `Quick (fun () ->
        with_state_dir (fun _dir ->
            Instance_store.set_launching ~instance_name:"partial-list"
              ~target:".#dev" ~unit_id:"partial0001";
            let entries = Instance_store.list () in
            let names = List.map fst entries in
            Alcotest.(check bool)
              "partial instance in list" true
              (List.mem "partial-list" names)));
    Alcotest.test_case "remove cleans up partial runtime instance" `Quick
      (fun () ->
        with_state_dir (fun _dir ->
            Instance_store.set_launching ~instance_name:"partial-rm"
              ~target:".#dev" ~unit_id:"partial0002";
            Instance_store.remove "partial-rm";
            (match Instance_store.find "partial-rm" with
            | None -> ()
            | Some _ ->
                Alcotest.fail "expected partial instance to be removed after rm");
            match Instance_store.find_runtime "partial-rm" with
            | None -> ()
            | Some _ ->
                Alcotest.fail
                  "expected partial runtime to be removed after rm"));
    Alcotest.test_case "clear_runtime on partial runtime removes runtime keeps target"
      `Quick (fun () ->
        with_state_dir (fun _dir ->
            Instance_store.set_launching ~instance_name:"partial-clear"
              ~target:".#dev" ~unit_id:"partial0003";
            Instance_store.clear_runtime "partial-clear";
            (match Instance_store.find "partial-clear" with
            | Some target ->
                Alcotest.(check string) "target preserved" ".#dev" target
            | None ->
                Alcotest.fail "expected target to remain after clear_runtime");
            match Instance_store.find_runtime "partial-clear" with
            | None -> ()
            | Some _ ->
                Alcotest.fail "expected runtime cleared"));
    Alcotest.test_case "runtime without ssh_key_path returns None (stale)"
      `Quick (fun () ->
        with_state_dir (fun dir ->
            let instance_dir = Filename.concat dir "stale-key" in
            Unix.mkdir instance_dir 0o755;
            let target_path = Filename.concat instance_dir "target" in
            let oc = open_out target_path in
            output_string oc ".#test\n";
            close_out oc;
            let runtime_path = Filename.concat instance_dir "runtime" in
            let oc = open_out runtime_path in
            Printf.fprintf oc "unit_id=stale0001\n";
            Printf.fprintf oc "serial_socket=/tmp/s.sock\n";
            Printf.fprintf oc "disk=/tmp/d.img\n";
            close_out oc;
            match Instance_store.find_runtime "stale-key" with
            | None -> ()
            | Some _ ->
                Alcotest.fail
                  "expected stale runtime without ssh_key_path to return None"));
  ]
