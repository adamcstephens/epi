open Test_helpers
open Mock_runtime

let tests ~bin =
  [
    Alcotest.test_case "stop clears runtime and reports success"
      `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                let result =
                  run_cli_with_env ~bin ~state_dir ~extra_env
                    [ "launch"; "stop-test"; "--target"; ".#dev" ]
                in
                assert_success ~context:"up for stop test" result;
                let entry = find_state_runtime ~state_dir "stop-test" in
                (match entry with
                | Some (Some _, _, _, _, _) -> ()
                | _ -> fail "expected unit_id in state after up");
                let down_result =
                  run_cli_with_env ~bin ~state_dir ~extra_env
                    [ "stop"; "stop-test" ]
                in
                assert_success ~context:"stop" down_result;
                let entry_after = find_state_runtime ~state_dir "stop-test" in
                (match entry_after with
                | None -> ()
                | _ ->
                    fail
                      "expected runtime to be cleared after stop"))));
  ]
