open Test_helpers
open Mock_runtime

let tests ~bin =
  [
    Alcotest.test_case "up with --mount passes --fs to cloud-hypervisor" `Quick
      (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log ~disk:_ ->
            with_state_dir (fun state_dir ->
                with_temp_dir "epi-mount-test" (fun mount_dir ->
                    let result =
                      run_cli_with_env ~bin ~state_dir ~extra_env
                        [ "launch"; "mount-test"; "--target"; ".#dev";
                          "--mount"; mount_dir ]
                    in
                    assert_success ~context:"up with --mount" result;
                    let launch_contents =
                      if Sys.file_exists launch_log then read_file launch_log
                      else ""
                    in
                    assert_contains ~context:"--fs in cloud-hypervisor args"
                      launch_contents "--fs";
                    assert_contains ~context:"hostfs tag in --fs arg"
                      launch_contents "hostfs"))));
    Alcotest.test_case
      "up with --mount includes mount paths in epi.json" `Quick
      (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                with_temp_dir "epi-mount-userdata-test" (fun mount_dir ->
                    let result =
                      run_cli_with_env ~bin ~state_dir ~extra_env
                        [ "launch"; "mount-userdata-test"; "--target"; ".#dev";
                          "--mount"; mount_dir ]
                    in
                    assert_success ~context:"up with --mount userdata" result;
                    let epi_json_path =
                      Filename.concat
                        (Filename.concat
                          (Filename.concat state_dir "mount-userdata-test")
                          "epidata")
                        "epi.json"
                    in
                    if not (Sys.file_exists epi_json_path) then
                      fail "expected epi.json in epidata staging dir";
                    let content = read_file epi_json_path in
                    assert_contains ~context:"mount path in epi.json"
                      content mount_dir))));
    Alcotest.test_case "up without --mount omits mounts from epi.json" `Quick
      (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                let result =
                  run_cli_with_env ~bin ~state_dir ~extra_env
                    [ "launch"; "no-mount-test"; "--target"; ".#dev" ]
                in
                assert_success ~context:"up without --mount" result;
                let epi_json_path =
                  Filename.concat
                    (Filename.concat
                      (Filename.concat state_dir "no-mount-test")
                      "epidata")
                    "epi.json"
                in
                let content = read_file epi_json_path in
                if contains content "\"mounts\"" then
                  fail
                    "epi.json should not contain mounts when --mount not used")));
    Alcotest.test_case
      "up with --mount and unconfigured user includes uid in epi.json" `Quick
      (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                with_temp_dir "epi-mount-uid-test" (fun mount_dir ->
                    let result =
                      run_cli_with_env ~bin ~state_dir ~extra_env
                        [ "launch"; "mount-uid-test"; "--target"; ".#dev";
                          "--mount"; mount_dir ]
                    in
                    assert_success ~context:"up --mount uid" result;
                    let epi_json_path =
                      Filename.concat
                        (Filename.concat
                          (Filename.concat state_dir "mount-uid-test")
                          "epidata")
                        "epi.json"
                    in
                    let content = read_file epi_json_path in
                    assert_contains ~context:"uid present in epi.json"
                      content "\"uid\""))));
    Alcotest.test_case
      "up with --mount and pre-configured user does not include uid" `Quick
      (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                with_temp_dir "epi-mount-no-uid-test" (fun mount_dir ->
                    let result =
                      run_cli_with_env ~bin ~state_dir ~extra_env
                        [ "launch"; "mount-no-uid-test";
                          "--target"; ".#user-configured";
                          "--mount"; mount_dir ]
                    in
                    assert_success ~context:"up --mount configured user" result;
                    let epi_json_path =
                      Filename.concat
                        (Filename.concat
                          (Filename.concat state_dir "mount-no-uid-test")
                          "epidata")
                        "epi.json"
                    in
                    let content = read_file epi_json_path in
                    if contains content "\"uid\"" then
                      fail
                        "epi.json should not contain uid for pre-configured user"))));
    Alcotest.test_case "up with --mount stores unit_id in state" `Quick
      (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                with_temp_dir "epi-virtiofsd-unit-test" (fun mount_dir ->
                    let result =
                      run_cli_with_env ~bin ~state_dir ~extra_env
                        [ "launch"; "virtiofsd-unit-test"; "--target"; ".#dev";
                          "--mount"; mount_dir ]
                    in
                    assert_success ~context:"up with --mount unit_id"
                      result;
                    match
                      find_state_runtime ~state_dir "virtiofsd-unit-test"
                    with
                    | Some (Some _, _, _, _, _) -> ()
                    | _ ->
                        fail
                          "expected unit_id to be stored in runtime state"))));
    Alcotest.test_case "up with --mount pointing to a file fails with clear error"
      `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                with_temp_dir "epi-mount-file-test" (fun tmp_dir ->
                    let file_path = Filename.concat tmp_dir "myfile.txt" in
                    write_file file_path "contents";
                    let result =
                      run_cli_with_env ~bin ~state_dir ~extra_env
                        [ "launch"; "mount-file-test"; "--target"; ".#dev";
                          "--mount"; file_path ]
                    in
                    assert_failure ~context:"--mount on a file" result;
                    let _, _, stderr = result in
                    assert_contains ~context:"not a directory error" stderr
                      "not a directory";
                    assert_contains ~context:"path in error" stderr file_path))));
  ]
