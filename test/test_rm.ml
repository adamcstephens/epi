open Test_helpers
open Mock_runtime

let tests ~bin =
  [
    Alcotest.test_case "removes stopped instances from state"
      `Quick (fun () ->
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
        with_state_dir (fun state_dir ->
            with_sleep_process (fun pid ->
                write_state_entry ~state_dir ~instance_name:"dev-a"
                  ~target:".#dev-a" ~pid
                  ~serial_socket:"/tmp/dev-a.serial.sock"
                  ~disk:"/tmp/dev-a.disk" ();
                let rejected = run_cli ~bin ~state_dir [ "rm"; "dev-a" ] in
                assert_failure ~context:"rm running without force" rejected;
                let _, _, err = rejected in
                assert_contains ~context:"rm running rejection message" err
                  "Instance 'dev-a' is running";
                assert_contains ~context:"rm running rejection guidance" err
                  "use `epi rm --force dev-a`";
                match find_state_runtime ~state_dir "dev-a" with
                | Some (Some active_pid, _, _, _, _, _, _)
                  when active_pid = pid ->
                    ()
                | _ -> fail "expected running instance to remain in state")));
    Alcotest.test_case "--force terminates running instance before removing"
      `Quick (fun () ->
        with_state_dir (fun state_dir ->
            with_sleep_process (fun pid ->
                write_state_entry ~state_dir ~instance_name:"dev-a"
                  ~target:".#dev-a" ~pid
                  ~serial_socket:"/tmp/dev-a.serial.sock"
                  ~disk:"/tmp/dev-a.disk" ();
                let removed =
                  run_cli ~bin ~state_dir [ "rm"; "--force"; "dev-a" ]
                in
                assert_success ~context:"rm force running" removed;
                let _, out, _ = removed in
                assert_contains ~context:"rm force output" out
                  "rm: removed instance=dev-a";
                assert_missing_state_entry ~context:"rm force state cleanup"
                  ~state_dir "dev-a")));
    Alcotest.test_case "--force reports termination errors and keeps state"
      `Quick (fun () ->
        if Unix.geteuid () = 0 then ()
        else
          with_state_dir (fun state_dir ->
              write_state_entry ~state_dir ~instance_name:"protected"
                ~target:".#protected" ~pid:1
                ~serial_socket:"/tmp/protected.serial.sock"
                ~disk:"/tmp/protected.disk" ();
              let failed =
                run_cli ~bin ~state_dir [ "rm"; "--force"; "protected" ]
              in
              assert_failure ~context:"rm force termination failure" failed;
              let _, _, err = failed in
              assert_contains ~context:"rm force termination failure output" err
                "failed to terminate";
              match find_state_runtime ~state_dir "protected" with
              | Some (Some 1, _, _, _, _, _, _) -> ()
              | _ -> fail "expected entry to remain after failed force removal"));
    Alcotest.test_case "kills passt process when hypervisor is already dead"
      `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                let result =
                  run_cli_with_env ~bin ~state_dir ~extra_env
                    [ "up"; "stale-rm"; "--target"; ".#dev" ]
                in
                assert_success ~context:"up for stale rm" result;
                let entry = find_state_runtime ~state_dir "stale-rm" in
                let hypervisor_pid =
                  match entry with
                  | Some (Some pid, _, _, _, _, _, _) -> pid
                  | _ -> fail "expected pid in state after up"
                in
                let passt_pid =
                  match entry with
                  | Some (_, _, _, Some pid, _, _, _) -> pid
                  | _ -> fail "expected passt_pid in state after up"
                in
                terminate_pid hypervisor_pid;
                if not (pid_is_alive passt_pid) then
                  fail "passt should be alive before rm";
                let rm_result =
                  run_cli_with_env ~bin ~state_dir ~extra_env
                    [ "rm"; "stale-rm" ]
                in
                assert_success ~context:"rm stale with passt" rm_result;
                if not (wait_for_pid_to_die ~attempts:40 passt_pid) then
                  fail "passt process should be dead after rm")));
  ]
