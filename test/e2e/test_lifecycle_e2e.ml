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
          E2e_helpers.provision_and_wait ~instance_name ~target ~mount_paths:[] ()
        in
        latest_runtime := Some runtime;

        let out = E2e_helpers.ssh_exec runtime [ "echo"; "ok" ] in
        Alcotest.(check string) "ssh works" "ok" (String.trim out);

        E2e_helpers.check_disk_grew runtime;

        let init_status = E2e_helpers.ssh_exec runtime [ "systemctl"; "is-active"; "epi-init" ] in
        Alcotest.(check string) "epi-init succeeded" "active" (String.trim init_status);

        let runtime2 =
          E2e_helpers.restart_instance ~instance_name ~target runtime
        in
        latest_runtime := Some runtime2;

        let out2 = E2e_helpers.ssh_exec runtime2 [ "echo"; "ok" ] in
        Alcotest.(check string) "ssh works after restart" "ok"
          (String.trim out2);

        ignore (Epi.stop_instance ~instance_name runtime2);
        Epi.Instance_store.remove instance_name;
        latest_runtime := None;

        let instances = Epi.Instance_store.list () in
        let found =
          List.exists (fun (name, _) -> name = instance_name) instances
        in
        Alcotest.(check bool) "instance removed" false found));
  ]
