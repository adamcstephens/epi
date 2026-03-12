open Test_helpers
open Mock_runtime

let tests ~bin =
  [
    Alcotest.test_case "shows empty and multi-instance state" `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                let empty =
                  run_cli_with_env ~bin ~state_dir ~extra_env [ "list" ]
                in
                assert_success ~context:"list empty" empty;
                let _, empty_out, _ = empty in
                assert_contains ~context:"list empty output" empty_out
                  "No instances found.";
                ignore
                  (run_cli_with_env ~bin ~state_dir ~extra_env
                     [ "launch"; "--target"; ".#default" ]);
                ignore
                  (run_cli_with_env ~bin ~state_dir ~extra_env
                     [ "launch"; "qa-1"; "--target"; "github:org/repo#qa-1" ]);
                let listed =
                  run_cli_with_env ~bin ~state_dir ~extra_env [ "list" ]
                in
                assert_success ~context:"list multi" listed;
                let _, listed_out, _ = listed in
                assert_contains ~context:"list header" listed_out
                  "INSTANCE\tTARGET\tSTATUS\tSSH";
                assert_contains ~context:"list default running" listed_out
                  "default\t.#default\trunning\t";
                assert_contains ~context:"list qa running" listed_out
                  "qa-1\tgithub:org/repo#qa-1\trunning\t")));
  ]
