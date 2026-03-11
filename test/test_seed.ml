open Test_helpers
open Mock_runtime

let tests ~bin =
  [
    Alcotest.test_case "missing xorriso produces a clear error"
      `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                let extra_env =
                  List.filter
                    (fun (key, _) ->
                      not (String.equal key "EPI_XORRISO_BIN"))
                    extra_env
                  @ [ ("EPI_XORRISO_BIN", "nonexistent-xorriso-bin") ]
                in
                let result =
                  run_cli_with_env ~bin ~state_dir ~extra_env
                    [ "launch"; "no-xorriso"; "--target"; ".#dev" ]
                in
                assert_failure ~context:"missing xorriso" result;
                let _, _, err = result in
                assert_contains ~context:"xorriso error message" err
                  "xorriso not found";
                assert_contains ~context:"xorriso install hint" err
                  "xorriso")));
    Alcotest.test_case "seed ISO is passed as --disk argument to cloud-hypervisor"
      `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log ~disk:_ ->
            with_state_dir (fun state_dir ->
                let result =
                  run_cli_with_env ~bin ~state_dir ~extra_env
                    [ "launch"; "disk-test"; "--target"; ".#dev" ]
                in
                assert_success ~context:"seed iso disk arg up" result;
                let launch_contents =
                  if Sys.file_exists launch_log then read_file launch_log
                  else ""
                in
                assert_contains ~context:"seed iso disk arg" launch_contents
                  "epidata.iso,readonly=on";
                assert_contains ~context:"passt net arg" launch_contents
                  "--net vhost_user=true,socket=")));
  ]
