open Test_helpers
open Mock_runtime

let tests ~bin =
  [
    Alcotest.test_case "runtime round-trips ssh_port correctly" `Quick
      (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                let result =
                  run_cli_with_env ~bin ~state_dir ~extra_env
                    [ "launch"; "tsv-roundtrip"; "--target"; ".#dev" ]
                in
                assert_success ~context:"tsv roundtrip up" result;
                let entry = find_state_runtime ~state_dir "tsv-roundtrip" in
                match entry with
                | Some (_, _, _, Some port_str, _) ->
                    let port = int_of_string port_str in
                    if port < 1 || port > 65535 then
                      fail "ssh_port out of range: %d" port
                | Some (_, _, _, None, _) ->
                    fail "expected ssh_port to be set after up"
                | None -> fail "expected state entry for tsv-roundtrip")));
  ]
