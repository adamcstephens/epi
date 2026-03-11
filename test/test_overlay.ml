open Test_helpers
open Mock_runtime

let tests ~bin =
  [
    Alcotest.test_case "overlay-store target starts nix-store virtiofsd" `Quick
      (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log ~virtiofsd_log ~disk:_ ->
            with_state_dir (fun state_dir ->
                let result =
                  run_cli_with_env ~bin ~state_dir ~extra_env
                    [ "launch"; "overlay-vm"; "--target"; ".#overlay-store" ]
                in
                assert_success ~context:"overlay launch" result;
                let launch_contents =
                  if Sys.file_exists launch_log then read_file launch_log
                  else ""
                in
                assert_contains ~context:"nix-store --fs arg"
                  launch_contents "tag=nix-store";
                let virtiofsd_contents =
                  if Sys.file_exists virtiofsd_log then read_file virtiofsd_log
                  else ""
                in
                assert_contains ~context:"virtiofsd shared /nix"
                  virtiofsd_contents "--shared-dir /nix")));
    Alcotest.test_case "overlay-store requires virtiofsd even without --mount" `Quick
      (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~virtiofsd_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                let extra_env =
                  List.filter
                    (fun (key, _) ->
                      not (String.equal key "EPI_VIRTIOFSD_BIN"))
                    extra_env
                  @ [ ("EPI_VIRTIOFSD_BIN", "nonexistent-virtiofsd-bin") ]
                in
                let result =
                  run_cli_with_env ~bin ~state_dir ~extra_env
                    [ "launch"; "overlay-no-vfsd"; "--target"; ".#overlay-store" ]
                in
                assert_failure ~context:"overlay missing virtiofsd" result;
                let _, _, err = result in
                assert_contains ~context:"virtiofsd error" err "virtiofsd")));
    Alcotest.test_case "non-overlay target does not start nix-store virtiofsd" `Quick
      (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log ~virtiofsd_log ~disk:_ ->
            with_state_dir (fun state_dir ->
                let result =
                  run_cli_with_env ~bin ~state_dir ~extra_env
                    [ "launch"; "non-overlay-vm"; "--target"; ".#dev" ]
                in
                assert_success ~context:"non-overlay launch" result;
                let launch_contents =
                  if Sys.file_exists launch_log then read_file launch_log
                  else ""
                in
                if contains launch_contents "nix-store" then
                  fail "nix-store virtiofsd should not be started for non-overlay target";
                let virtiofsd_contents =
                  if Sys.file_exists virtiofsd_log then read_file virtiofsd_log
                  else ""
                in
                if contains virtiofsd_contents "/nix" then
                  fail "virtiofsd for /nix should not be started for non-overlay target")));
    Alcotest.test_case "overlay-store with --mount starts both virtiofsd instances" `Quick
      (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log ~virtiofsd_log ~disk:_ ->
            with_state_dir (fun state_dir ->
                with_temp_dir "epi-overlay-mount" (fun mount_dir ->
                    let result =
                      run_cli_with_env ~bin ~state_dir ~extra_env
                        [ "launch"; "overlay-mount-vm"; "--target"; ".#overlay-store";
                          "--mount"; mount_dir ]
                    in
                    assert_success ~context:"overlay+mount launch" result;
                    let launch_contents =
                      if Sys.file_exists launch_log then read_file launch_log
                      else ""
                    in
                    assert_contains ~context:"nix-store --fs arg"
                      launch_contents "tag=nix-store";
                    assert_contains ~context:"hostfs --fs arg"
                      launch_contents "tag=hostfs-0";
                    let virtiofsd_contents =
                      if Sys.file_exists virtiofsd_log then read_file virtiofsd_log
                      else ""
                    in
                    assert_contains ~context:"virtiofsd shared /nix"
                      virtiofsd_contents "--shared-dir /nix";
                    assert_contains ~context:"virtiofsd shared mount dir"
                      virtiofsd_contents mount_dir))));
  ]
