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
                        [ "up"; "mount-test"; "--target"; ".#dev";
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
      "up with --mount writes mounts directive in cloud-init user-data" `Quick
      (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                with_temp_dir "epi-mount-userdata-test" (fun mount_dir ->
                    let result =
                      run_cli_with_env ~bin ~state_dir ~extra_env
                        [ "up"; "mount-userdata-test"; "--target"; ".#dev";
                          "--mount"; mount_dir ]
                    in
                    assert_success ~context:"up with --mount userdata" result;
                    let user_data_path =
                      Filename.concat
                        (Filename.concat
                          (Filename.concat state_dir "mount-userdata-test")
                          "cidata")
                        "user-data"
                    in
                    let user_data = read_file user_data_path in
                    assert_contains ~context:"write_files directive present"
                      user_data "write_files:";
                    assert_contains ~context:"systemd mount unit type" user_data
                      "Type=virtiofs";
                    assert_contains ~context:"systemd mount unit where" user_data
                      (Printf.sprintf "Where=%s" mount_dir);
                    assert_contains ~context:"runcmd starts unit" user_data
                      "systemctl start";
                    assert_contains ~context:"mount path matches host path"
                      user_data mount_dir))));
    Alcotest.test_case "up without --mount does not write runcmd mount" `Quick
      (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                let result =
                  run_cli_with_env ~bin ~state_dir ~extra_env
                    [ "up"; "no-mount-test"; "--target"; ".#dev" ]
                in
                assert_success ~context:"up without --mount" result;
                let user_data_path =
                  Filename.concat
                    (Filename.concat
                      (Filename.concat state_dir "no-mount-test")
                      "cidata")
                    "user-data"
                in
                let user_data = read_file user_data_path in
                if contains user_data "write_files:" then
                  fail
                    "user-data should not contain write_files: when --mount \
                     not used")));
    Alcotest.test_case
      "up with --mount and unconfigured user includes uid in cloud-init" `Quick
      (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                with_temp_dir "epi-mount-uid-test" (fun mount_dir ->
                    let result =
                      run_cli_with_env ~bin ~state_dir ~extra_env
                        [ "up"; "mount-uid-test"; "--target"; ".#dev";
                          "--mount"; mount_dir ]
                    in
                    assert_success ~context:"up --mount uid" result;
                    let user_data_path =
                      Filename.concat
                        (Filename.concat
                          (Filename.concat state_dir "mount-uid-test")
                          "cidata")
                        "user-data"
                    in
                    let user_data = read_file user_data_path in
                    assert_contains ~context:"uid present in user-data"
                      user_data "uid:"))));
    Alcotest.test_case
      "up with --mount and pre-configured user does not include uid" `Quick
      (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                with_temp_dir "epi-mount-no-uid-test" (fun mount_dir ->
                    let result =
                      run_cli_with_env ~bin ~state_dir ~extra_env
                        [ "up"; "mount-no-uid-test";
                          "--target"; ".#user-configured";
                          "--mount"; mount_dir ]
                    in
                    assert_success ~context:"up --mount configured user" result;
                    let user_data_path =
                      Filename.concat
                        (Filename.concat
                          (Filename.concat state_dir "mount-no-uid-test")
                          "cidata")
                        "user-data"
                    in
                    let user_data = read_file user_data_path in
                    if contains user_data "uid:" then
                      fail
                        "user-data should not contain uid: for pre-configured \
                         user"))));
    Alcotest.test_case "up with --mount tracks virtiofsd_pid in state" `Quick
      (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                with_temp_dir "epi-virtiofsd-pid-test" (fun mount_dir ->
                    let result =
                      run_cli_with_env ~bin ~state_dir ~extra_env
                        [ "up"; "virtiofsd-pid-test"; "--target"; ".#dev";
                          "--mount"; mount_dir ]
                    in
                    assert_success ~context:"up with --mount virtiofsd pid"
                      result;
                    match
                      find_state_runtime ~state_dir "virtiofsd-pid-test"
                    with
                    | Some (Some _, _, _, _, _ :: _, _, _) -> ()
                    | _ ->
                        fail
                          "expected virtiofsd_pids to be stored in runtime \
                           state"))));
    Alcotest.test_case "up with --mount pointing to a file fails with clear error"
      `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                with_temp_dir "epi-mount-file-test" (fun tmp_dir ->
                    let file_path = Filename.concat tmp_dir "myfile.txt" in
                    write_file file_path "contents";
                    let result =
                      run_cli_with_env ~bin ~state_dir ~extra_env
                        [ "up"; "mount-file-test"; "--target"; ".#dev";
                          "--mount"; file_path ]
                    in
                    assert_failure ~context:"--mount on a file" result;
                    let _, _, stderr = result in
                    assert_contains ~context:"not a directory error" stderr
                      "not a directory";
                    assert_contains ~context:"path in error" stderr file_path))));
  ]
