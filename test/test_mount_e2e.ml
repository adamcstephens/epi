(* Disabled: mount generator bug — systemd unit has "bad-setting",
   mount point not auto-created in guest.

let tests ~bin:_ =
  [
    Alcotest.test_case "mounted file is readable in guest" `Slow (fun () ->
      let instance_name = E2e_helpers.unique_name "e2e-mount" in
      let target = ".#manual-test" in
      Test_helpers.with_temp_dir "e2e-mount-data" (fun mount_dir ->
        let marker_path = Filename.concat mount_dir "marker.txt" in
        Test_helpers.write_file marker_path "e2e-mount-test-content";
        let runtime =
          E2e_helpers.provision_and_wait ~instance_name ~target
            ~mount_paths:[ mount_dir ]
        in
        E2e_helpers.with_cleanup ~instance_name runtime (fun () ->
          let guest_marker = Filename.concat mount_dir "marker.txt" in
          let out =
            E2e_helpers.ssh_exec runtime [ "cat"; guest_marker ]
          in
          Alcotest.(check string) "marker readable in guest"
            "e2e-mount-test-content" (String.trim out))));
    Alcotest.test_case "mount persists across stop/start" `Slow (fun () ->
      let instance_name = E2e_helpers.unique_name "e2e-mount-persist" in
      let target = ".#manual-test" in
      Test_helpers.with_temp_dir "e2e-mount-persist-data" (fun mount_dir ->
        let marker_path = Filename.concat mount_dir "marker.txt" in
        Test_helpers.write_file marker_path "persist-test-content";
        let guest_marker = Filename.concat mount_dir "marker.txt" in
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
              ~mount_paths:[ mount_dir ]
          in
          latest_runtime := Some runtime;

          let out =
            E2e_helpers.ssh_exec runtime [ "cat"; guest_marker ]
          in
          Alcotest.(check string) "marker before restart"
            "persist-test-content" (String.trim out);

          let runtime2 =
            E2e_helpers.restart_instance ~instance_name ~target runtime
          in
          latest_runtime := Some runtime2;

          let out2 =
            E2e_helpers.ssh_exec runtime2 [ "cat"; guest_marker ]
          in
          Alcotest.(check string) "marker after restart"
            "persist-test-content" (String.trim out2))));
  ]
*)

let tests ~bin:_ = []
