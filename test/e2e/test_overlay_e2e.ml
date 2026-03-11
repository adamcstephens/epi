let tests =
  [
    Alcotest.test_case "overlay VM boots and shares host nix store" `Slow
      (fun () ->
        let instance_name = E2e_helpers.unique_name "e2e-overlay" in
        let target = ".#overlay-test" in
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

          (* SSH works *)
          let out = E2e_helpers.ssh_exec runtime [ "echo"; "ok" ] in
          Alcotest.(check string) "ssh works" "ok" (String.trim out);

          E2e_helpers.check_disk_grew runtime;

          (* /nix/store is an overlay mount *)
          let mount_out =
            E2e_helpers.ssh_exec runtime [ "mount" ]
          in
          Alcotest.(check bool) "/nix/store is overlay" true
            (Test_helpers.contains mount_out "fuse-overlayfs on /nix/store");

          (* host nix store paths are visible *)
          let ls_out =
            E2e_helpers.ssh_exec runtime [ "ls"; "/nix/store" ]
          in
          Alcotest.(check bool) "store has entries" true
            (String.trim ls_out <> "");

          (* nix path-info for a path that exists on host *)
          let path_out =
            E2e_helpers.ssh_exec runtime
              [ "nix"; "path-info"; "/run/current-system" ]
          in
          Alcotest.(check bool) "nix path-info succeeds" true
            (String.length (String.trim path_out) > 0);

          (* upper layer is writable - install to upper *)
          let write_out =
            E2e_helpers.ssh_exec runtime
              [ "nix-store"; "--add"; "/etc/hostname" ]
          in
          Alcotest.(check bool) "nix-store --add succeeds" true
            (String.length (String.trim write_out) > 0);

          (* verify the added path lands in upper layer *)
          let upper_out =
            E2e_helpers.ssh_exec runtime [ "ls"; "/var/nix-overlay/upper" ]
          in
          Alcotest.(check bool) "upper layer has content" true
            (String.trim upper_out <> "")));
    Alcotest.test_case "overlay store paths persist across reboot" `Slow
      (fun () ->
        let instance_name = E2e_helpers.unique_name "e2e-overlay-persist" in
        let target = ".#overlay-test" in
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

          (* Write a marker to the upper layer *)
          let added_path =
            String.trim
              (E2e_helpers.ssh_exec runtime
                 [ "nix-store"; "--add"; "/etc/hostname" ])
          in
          Alcotest.(check bool) "store --add produced path" true
            (String.length added_path > 0);

          (* Restart the instance *)
          let runtime2 =
            E2e_helpers.restart_instance ~instance_name ~target runtime
          in
          latest_runtime := Some runtime2;

          (* Verify the path persists *)
          let exists_out =
            E2e_helpers.ssh_exec runtime2
              [ "test"; "-e"; added_path; "&&"; "echo"; "exists" ]
          in
          Alcotest.(check string) "upper layer path persists" "exists"
            (String.trim exists_out)));
    Alcotest.test_case "overlay VM with --mount has both virtiofs shares" `Slow
      (fun () ->
        let instance_name = E2e_helpers.unique_name "e2e-overlay-mount" in
        let target = ".#overlay-test" in
        Test_helpers.with_temp_dir "e2e-overlay-mount-data" (fun mount_dir ->
          let marker_path = Filename.concat mount_dir "marker.txt" in
          Test_helpers.write_file marker_path "overlay-mount-test";
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
                ~mount_paths:[ mount_dir ] ()
            in
            latest_runtime := Some runtime;

            (* Overlay is working *)
            let mount_out =
              E2e_helpers.ssh_exec runtime [ "mount" ]
            in
            Alcotest.(check bool) "/nix/store is overlay" true
              (Test_helpers.contains mount_out "fuse-overlayfs on /nix/store");

            (* User mount is also working *)
            let guest_marker = Filename.concat mount_dir "marker.txt" in
            let out =
              E2e_helpers.ssh_exec runtime [ "cat"; guest_marker ]
            in
            Alcotest.(check string) "user mount readable"
              "overlay-mount-test" (String.trim out))));
  ]
