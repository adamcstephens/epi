open Test_helpers
open Mock_runtime

let tests ~bin =
  [
    Alcotest.test_case "removes stopped instances from state" `Quick (fun () ->
        with_state_dir (fun state_dir ->
            write_state_entry ~state_dir ~instance_name:"dev-a"
              ~target:".#dev-a" ();
            let removed = run_cli ~bin ~state_dir [ "rm"; "dev-a" ] in
            assert_success ~context:"rm stopped instance" removed;
            let _, out, _ = removed in
            assert_contains ~context:"rm stopped output" out
              "rm: removed instance=dev-a";
            assert_missing_state_entry ~context:"rm stopped state cleanup"
              ~state_dir "dev-a"));
    Alcotest.test_case "refuses to remove running instance without --force"
      `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                let launch_result =
                  run_cli_with_env ~bin ~state_dir ~extra_env
                    [ "launch"; "dev-a"; "--target"; ".#dev-a" ]
                in
                assert_success ~context:"launch for rm test" launch_result;
                let rejected =
                  run_cli_with_env ~bin ~state_dir ~extra_env [ "rm"; "dev-a" ]
                in
                assert_failure ~context:"rm running without force" rejected;
                let _, _, err = rejected in
                assert_contains ~context:"rm running rejection message" err
                  "Instance 'dev-a' is running";
                assert_contains ~context:"rm running rejection guidance" err
                  "use `epi rm --force dev-a`")));
    Alcotest.test_case "--force terminates running instance before removing"
      `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                let launch_result =
                  run_cli_with_env ~bin ~state_dir ~extra_env
                    [ "launch"; "dev-a"; "--target"; ".#dev-a" ]
                in
                assert_success ~context:"launch for rm force test" launch_result;
                let removed =
                  run_cli_with_env ~bin ~state_dir ~extra_env
                    [ "rm"; "--force"; "dev-a" ]
                in
                assert_success ~context:"rm force running" removed;
                let _, out, _ = removed in
                assert_contains ~context:"rm force output" out
                  "rm: removed instance=dev-a";
                assert_missing_state_entry ~context:"rm force state cleanup"
                  ~state_dir "dev-a")));
    Alcotest.test_case "rm stale instance succeeds" `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                let result =
                  run_cli_with_env ~bin ~state_dir ~extra_env
                    [ "launch"; "stale-rm"; "--target"; ".#dev" ]
                in
                assert_success ~context:"up for stale rm" result;
                let unit_id =
                  match find_state_runtime ~state_dir "stale-rm" with
                  | Some (Some uid, _, _, _, _) -> uid
                  | _ -> fail "expected unit_id in state after up"
                in
                (* Stop the VM to make the runtime stale *)
                ignore
                  (stop_unit (vm_unit_name ~instance_name:"stale-rm" ~unit_id));
                let rm_result =
                  run_cli_with_env ~bin ~state_dir ~extra_env
                    [ "rm"; "stale-rm" ]
                in
                assert_success ~context:"rm stale" rm_result;
                assert_missing_state_entry ~context:"rm stale state cleanup"
                  ~state_dir "stale-rm")));
  ]
