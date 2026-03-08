open Test_helpers
open Mock_runtime

let tests ~bin =
  [
    Alcotest.test_case "terminates passt process alongside hypervisor"
      `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                let result =
                  run_cli_with_env ~bin ~state_dir ~extra_env
                    [ "up"; "passt-kill-test"; "--target"; ".#dev" ]
                in
                assert_success ~context:"up for passt kill test" result;
                let entry = find_state_runtime ~state_dir "passt-kill-test" in
                let passt_pid =
                  match entry with
                  | Some (_, _, _, Some pid, _, _, _) -> pid
                  | _ -> fail "expected passt_pid in state after up"
                in
                if not (pid_is_alive passt_pid) then
                  fail "passt process should be alive before down";
                let down_result =
                  run_cli_with_env ~bin ~state_dir ~extra_env
                    [ "down"; "passt-kill-test" ]
                in
                assert_success ~context:"down passt kill" down_result;
                if not (wait_for_pid_to_die ~attempts:40 passt_pid) then
                  fail "passt process should be dead after down";
                let entry_after = find_state_runtime ~state_dir "passt-kill-test" in
                (match entry_after with
                | Some (None, _, _, _, _, _, _) | None -> ()
                | _ ->
                    fail
                      "expected runtime to be cleared but instance kept after down"))));
    Alcotest.test_case "terminates virtiofsd process" `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                with_temp_dir "epi-virtiofsd-down-test" (fun mount_dir ->
                    let up_result =
                      run_cli_with_env ~bin ~state_dir ~extra_env
                        [ "up"; "virtiofsd-down-test"; "--target"; ".#dev";
                          "--mount"; mount_dir ]
                    in
                    assert_success ~context:"up for virtiofsd down test"
                      up_result;
                    let virtiofsd_pid =
                      match
                        find_state_runtime ~state_dir "virtiofsd-down-test"
                      with
                      | Some (_, _, _, _, Some pid, _, _) -> pid
                      | _ -> fail "expected virtiofsd_pid after up"
                    in
                    if not (pid_is_alive virtiofsd_pid) then
                      fail "virtiofsd should be alive before down";
                    let down_result =
                      run_cli_with_env ~bin ~state_dir ~extra_env
                        [ "down"; "virtiofsd-down-test" ]
                    in
                    assert_success ~context:"down virtiofsd-down-test"
                      down_result;
                    if not (wait_for_pid_to_die ~attempts:80 virtiofsd_pid) then
                      fail
                        "virtiofsd process should be terminated after down"))));
  ]
