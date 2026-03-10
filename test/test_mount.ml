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
