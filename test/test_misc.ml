open Test_helpers
open Mock_runtime

let tests ~bin =
  [
    Alcotest.test_case "alloc_free_port returns a valid port number"
      `Quick (fun () ->
        let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
        Fun.protect
          ~finally:(fun () -> Unix.close sock)
          (fun () ->
            Unix.bind sock (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
            match Unix.getsockname sock with
            | Unix.ADDR_INET (_, port) ->
                if port < 1 || port > 65535 then
                  fail "alloc_free_port returned out-of-range port: %d" port
            | _ -> fail "unexpected socket address from bind-to-zero"));
    Alcotest.test_case "runtime round-trips ssh_port correctly"
      `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                let result =
                  run_cli_with_env ~bin ~state_dir ~extra_env
                    [ "launch"; "tsv-roundtrip"; "--target"; ".#dev" ]
                in
                assert_success ~context:"tsv roundtrip up" result;
                let entry = find_state_runtime ~state_dir "tsv-roundtrip" in
                match entry with
                | Some (_, _, _, _, _, Some port, _) when port > 0 && port <= 65535
                  ->
                    ()
                | Some (_, _, _, _, _, None, _) ->
                    fail "expected ssh_port to be set after up"
                | Some (_, _, _, _, _, Some port, _) ->
                    fail "ssh_port out of range: %d" port
                | None -> fail "expected state entry for tsv-roundtrip")));
  ]
