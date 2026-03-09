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
                ssh_key_path = Some "/tmp/test_key";
              }
            in
            Instance_store.set_provisioned ~instance_name:"roundtrip"
              ~target:".#test" ~runtime;
            match Instance_store.find_runtime "roundtrip" with
            | Some r ->
                Alcotest.(check string) "unit_id" "abcd1234" r.unit_id;
                Alcotest.(check string) "serial_socket" "/tmp/test.sock"
                  r.serial_socket;
                Alcotest.(check string) "disk" "/tmp/test.img" r.disk;
                Alcotest.(check (option int)) "ssh_port" (Some 2222)
                  r.ssh_port;
                Alcotest.(check (option string)) "ssh_key_path"
                  (Some "/tmp/test_key") r.ssh_key_path
            | None -> Alcotest.fail "expected runtime to be found"));
    Alcotest.test_case "save and load target round-trips" `Quick (fun () ->
        with_state_dir (fun _dir ->
            Instance_store.set ~instance_name:"target-rt" ~target:".#myvm";
            match Instance_store.find "target-rt" with
            | Some target ->
                Alcotest.(check string) "target" ".#myvm" target
            | None -> Alcotest.fail "expected target to be found"));
    Alcotest.test_case "list with empty dir returns empty" `Quick (fun () ->
        with_state_dir (fun _dir ->
            let entries = Instance_store.list () in
            Alcotest.(check int) "count" 0 (List.length entries)));
    Alcotest.test_case "list returns multiple instances sorted" `Quick (fun () ->
        with_state_dir (fun _dir ->
            Instance_store.set ~instance_name:"beta" ~target:".#beta";
            Instance_store.set ~instance_name:"alpha" ~target:".#alpha";
            Instance_store.set ~instance_name:"gamma" ~target:".#gamma";
            let entries = Instance_store.list () in
            let names = List.map fst entries in
            Alcotest.(check (list string)) "sorted"
              ["alpha"; "beta"; "gamma"] names));
    Alcotest.test_case "clear_runtime removes runtime but keeps entry"
      `Quick (fun () ->
        with_state_dir (fun _dir ->
            let runtime : Instance_store.runtime =
              {
                unit_id = "clear0001";
                serial_socket = "/tmp/s.sock";
                disk = "/tmp/d.img";
                ssh_port = None;
                ssh_key_path = None;
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
    Alcotest.test_case "runtime with optional fields as None round-trips"
      `Quick (fun () ->
        with_state_dir (fun _dir ->
            let runtime : Instance_store.runtime =
              {
                unit_id = "none0001";
                serial_socket = "/tmp/s.sock";
                disk = "/tmp/d.img";
                ssh_port = None;
                ssh_key_path = None;
              }
            in
            Instance_store.set_provisioned ~instance_name:"none-opts"
              ~target:".#test" ~runtime;
            match Instance_store.find_runtime "none-opts" with
            | Some r ->
                Alcotest.(check (option int)) "ssh_port" None r.ssh_port;
                Alcotest.(check (option string)) "ssh_key_path" None
                  r.ssh_key_path
            | None -> Alcotest.fail "expected runtime to be found"));
  ]
