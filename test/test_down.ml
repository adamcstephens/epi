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
    Alcotest.test_case "pre-stop hook runs before stopping"
      `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                with_temp_dir "epi-hooks" (fun hooks_dir ->
                    let hook_point_dir = Filename.concat hooks_dir "epi/hooks/pre-stop.d" in
                    let rec mkdir_p path =
                      if path = "." || path = "/" then ()
                      else if Sys.file_exists path then ()
                      else (mkdir_p (Filename.dirname path); Unix.mkdir path 0o755)
                    in
                    mkdir_p hook_point_dir;
                    let marker = Filename.concat hooks_dir "pre-stop-ran" in
                    let hook_script = Filename.concat hook_point_dir "mark" in
                    write_file hook_script
                      ("#!/bin/sh\ntouch " ^ marker ^ "\n");
                    make_executable hook_script;
                    let extra_env =
                      ("XDG_CONFIG_HOME", hooks_dir) :: extra_env
                    in
                    let result =
                      run_cli_with_env ~bin ~state_dir ~extra_env
                        [ "launch"; "hook-stop"; "--target"; ".#dev" ]
                    in
                    assert_success ~context:"launch for hook test" result;
                    let stop_result =
                      run_cli_with_env ~bin ~state_dir ~extra_env
                        [ "stop"; "hook-stop" ]
                    in
                    assert_success ~context:"stop with hook" stop_result;
                    if not (Sys.file_exists marker) then
                      fail "pre-stop hook did not run (marker file missing)"))));
  ]
