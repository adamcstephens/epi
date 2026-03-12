let tests =
  [
    Alcotest.test_case "provision, stop, start, remove" `Slow (fun () ->
        let instance_name = E2e_helpers.unique_name "e2e-lifecycle" in
        let target = ".#manual-test" in
        let latest_runtime = ref None in
        let cleanup () =
          (match !latest_runtime with
          | Some rt -> ignore (Epi.stop_instance ~instance_name rt)
          | None -> ());
          Epi.Instance_store.remove instance_name
        in
        Fun.protect ~finally:cleanup (fun () ->
            let runtime =
              E2e_helpers.provision_and_wait ~instance_name ~target
                ~mount_paths:[] ()
            in
            latest_runtime := Some runtime;

            let out = E2e_helpers.ssh_exec runtime [ "echo"; "ok" ] in
            Alcotest.(check string) "ssh works" "ok" (String.trim out);

            let log_path =
              Epi.Console.console_log_path instance_name
            in
            let log_exists = Sys.file_exists log_path in
            Alcotest.(check bool) "console.log exists" true log_exists;
            let log_content =
              In_channel.with_open_text log_path In_channel.input_all
            in
            let has_kernel =
              Epi.Util.contains log_content "Linux version"
            in
            Alcotest.(check bool)
              "console.log contains kernel output" true has_kernel;

            E2e_helpers.check_disk_grew runtime;

            let init_status =
              E2e_helpers.ssh_exec runtime
                [ "systemctl"; "is-active"; "epi-init" ]
            in
            Alcotest.(check string)
              "epi-init succeeded" "active" (String.trim init_status);

            let runtime2 =
              E2e_helpers.restart_instance ~instance_name ~target runtime
            in
            latest_runtime := Some runtime2;

            let out2 = E2e_helpers.ssh_exec runtime2 [ "echo"; "ok" ] in
            Alcotest.(check string)
              "ssh works after restart" "ok" (String.trim out2);

            ignore (Epi.stop_instance ~instance_name runtime2);
            Epi.Instance_store.remove instance_name;
            latest_runtime := None;

            let instances = Epi.Instance_store.list () in
            let found =
              List.exists (fun (name, _) -> name = instance_name) instances
            in
            Alcotest.(check bool) "instance removed" false found));
    Alcotest.test_case "partial runtime discoverable by list and cleanable by rm"
      `Slow (fun () ->
        let instance_name = E2e_helpers.unique_name "e2e-partial" in
        let target = ".#manual-test" in
        let runtime =
          E2e_helpers.provision_and_wait ~instance_name ~target ~mount_paths:[]
            ()
        in
        let unit_id = runtime.Epi.Instance_store.unit_id in
        Fun.protect
          ~finally:(fun () ->
            (* best-effort cleanup in case test fails *)
            (match Epi.Instance_store.find_runtime instance_name with
            | Some rt -> ignore (Epi.stop_instance ~instance_name rt)
            | None ->
                (* try with known unit_id *)
                (match
                   Epi.Instance_store.slice_name ~instance_name ~unit_id
                 with
                | Ok slice -> ignore (Epi.Process.stop_unit slice)
                | Error _ -> ()));
            Epi.Instance_store.remove instance_name)
          (fun () ->
            (* Replace state with partial runtime (simulating interrupted launch) *)
            Epi.Instance_store.set_launching ~instance_name ~target ~unit_id;

            (* Verify list sees the instance *)
            let instances = Epi.Instance_store.list () in
            let found =
              List.exists (fun (name, _) -> name = instance_name) instances
            in
            Alcotest.(check bool) "partial instance in list" true found;

            (* Verify runtime has only unit_id populated *)
            (match Epi.Instance_store.find_runtime instance_name with
            | Some r ->
                Alcotest.(check string) "unit_id preserved" unit_id r.unit_id;
                Alcotest.(check string)
                  "serial_socket empty" "" r.serial_socket;
                Alcotest.(check string) "disk empty" "" r.disk;
                Alcotest.(check string) "ssh_key_path empty" "" r.ssh_key_path
            | None -> Alcotest.fail "expected partial runtime to be loadable");

            (* Verify the VM slice is still running *)
            (match
               Epi.Instance_store.vm_unit_name ~instance_name ~unit_id
             with
            | Ok vm_unit ->
                Alcotest.(check bool)
                  "VM still running" true
                  (Epi.Process.unit_is_active vm_unit)
            | Error _ -> Alcotest.fail "could not construct vm unit name");

            (* Stop slice via unit_id from partial runtime and remove *)
            (match Epi.Instance_store.find_runtime instance_name with
            | Some rt -> ignore (Epi.stop_instance ~instance_name rt)
            | None -> Alcotest.fail "expected runtime for stop");
            Epi.Instance_store.remove instance_name;

            (* Verify VM is stopped *)
            (match
               Epi.Instance_store.vm_unit_name ~instance_name ~unit_id
             with
            | Ok vm_unit ->
                Alcotest.(check bool)
                  "VM stopped after rm" false
                  (Epi.Process.unit_is_active vm_unit)
            | Error _ -> ());

            (* Verify instance removed from list *)
            let instances2 = Epi.Instance_store.list () in
            let found2 =
              List.exists (fun (name, _) -> name = instance_name) instances2
            in
            Alcotest.(check bool) "instance removed from list" false found2));
  ]
