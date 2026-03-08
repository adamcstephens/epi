open Test_helpers
open Mock_runtime

let with_counting_resolver ~extra_env ~test_dir f =
  let cache_dir = Filename.concat test_dir "cache" in
  let resolver_log =
    Filename.concat test_dir "resolver-calls.log"
  in
  let counting_resolver =
    Filename.concat test_dir "counting-resolver.sh"
  in
  let original_resolver =
    List.assoc "EPI_TARGET_RESOLVER_CMD" extra_env
  in
  write_file counting_resolver
    ("#!/usr/bin/env sh\n\
      echo \"call\" >> \"" ^ resolver_log ^ "\"\n\
      exec \"" ^ original_resolver ^ "\" \"$@\"\n");
  make_executable counting_resolver;
  let extra_env =
    ("EPI_CACHE_DIR", cache_dir)
    :: List.map
         (fun (k, v) ->
           if String.equal k "EPI_TARGET_RESOLVER_CMD" then
             (k, counting_resolver)
           else (k, v))
         extra_env
  in
  f ~extra_env ~resolver_log

let count_resolver_calls resolver_log =
  if Sys.file_exists resolver_log then
    let log_content = read_file resolver_log in
    String.split_on_char '\n' log_content
    |> List.filter (fun line -> String.equal line "call")
    |> List.length
  else 0

let tests ~bin =
  [
    Alcotest.test_case "is written after successful provision"
      `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                with_temp_dir "epi-cache-home" (fun cache_dir ->
                    let extra_env = ("EPI_CACHE_DIR", cache_dir) :: extra_env in
                    let result =
                      run_cli_with_env ~bin ~state_dir ~extra_env
                        [ "launch"; "cache-write"; "--target"; ".#dev" ]
                    in
                    assert_success ~context:"cache write up" result;
                    let targets_dir =
                      Filename.concat cache_dir "targets"
                    in
                    if not (Sys.file_exists targets_dir) then
                      fail "cache targets directory was not created";
                    let entries = Sys.readdir targets_dir |> Array.to_list in
                    let descriptor_files =
                      List.filter
                        (fun name ->
                          let len = String.length name in
                          len > 11
                          && String.sub name (len - 11) 11 = ".descriptor")
                        entries
                    in
                    if descriptor_files = [] then
                      fail "no .descriptor cache file was created"))));
    Alcotest.test_case "second epi up on same target uses cache"
      `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                with_temp_dir "epi-cache-hit" (fun test_dir ->
                    with_counting_resolver ~extra_env ~test_dir
                      (fun ~extra_env ~resolver_log ->
                        let result1 =
                          run_cli_with_env ~bin ~state_dir ~extra_env
                            [ "launch"; "cache-hit"; "--target"; ".#dev" ]
                        in
                        assert_success ~context:"cache hit first up" result1;
                        let entry = find_state_runtime ~state_dir "cache-hit" in
                        let hypervisor_pid =
                          match entry with
                          | Some (Some pid, _, _, _, _, _, _) -> pid
                          | _ -> fail "expected pid after first up"
                        in
                        let passt_pid =
                          match entry with
                          | Some (_, _, _, Some pid, _, _, _) -> pid
                          | _ -> fail "expected passt_pid after first up"
                        in
                        terminate_pid hypervisor_pid;
                        terminate_pid passt_pid;
                        let _ = wait_for_pid_to_die ~attempts:20 hypervisor_pid in
                        let result2 =
                          run_cli_with_env ~bin ~state_dir ~extra_env
                            [ "launch"; "cache-hit"; "--target"; ".#dev" ]
                        in
                        assert_success ~context:"cache hit second up" result2;
                        let call_count = count_resolver_calls resolver_log in
                        if call_count <> 1 then
                          fail
                            "expected resolver to be called exactly once, got %d"
                            call_count)))));
    Alcotest.test_case "missing path triggers re-eval"
      `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                with_temp_dir "epi-cache-miss" (fun test_dir ->
                    with_counting_resolver ~extra_env ~test_dir
                      (fun ~extra_env ~resolver_log ->
                        let result1 =
                          run_cli_with_env ~bin ~state_dir ~extra_env
                            [ "launch"; "cache-miss"; "--target"; ".#dev" ]
                        in
                        assert_success ~context:"cache miss first up" result1;
                        let entry = find_state_runtime ~state_dir "cache-miss" in
                        let hypervisor_pid =
                          match entry with
                          | Some (Some pid, _, _, _, _, _, _) -> pid
                          | _ -> fail "expected pid after first up"
                        in
                        let passt_pid =
                          match entry with
                          | Some (_, _, _, Some pid, _, _, _) -> pid
                          | _ -> fail "expected passt_pid after first up"
                        in
                        terminate_pid hypervisor_pid;
                        terminate_pid passt_pid;
                        let _ = wait_for_pid_to_die ~attempts:20 hypervisor_pid in
                        let cache_dir = Filename.concat test_dir "cache" in
                        let targets_dir = Filename.concat cache_dir "targets" in
                        let cache_files = Sys.readdir targets_dir |> Array.to_list in
                        let cache_file =
                          match
                            List.find_opt
                              (fun name ->
                                let len = String.length name in
                                len > 11
                                && String.sub name (len - 11) 11 = ".descriptor")
                              cache_files
                          with
                          | Some name -> Filename.concat targets_dir name
                          | None -> fail "expected cache file after first up"
                        in
                        let cache_content = read_file cache_file in
                        let corrupted =
                          let lines = String.split_on_char '\n' cache_content in
                          List.map
                            (fun line ->
                              if
                                String.length line > 5
                                && String.sub line 0 5 = "disk="
                              then "disk=/nonexistent/path"
                              else line)
                            lines
                          |> String.concat "\n"
                        in
                        write_file cache_file corrupted;
                        let result2 =
                          run_cli_with_env ~bin ~state_dir ~extra_env
                            [ "launch"; "cache-miss"; "--target"; ".#dev" ]
                        in
                        assert_success ~context:"cache miss second up" result2;
                        let call_count = count_resolver_calls resolver_log in
                        if call_count <> 2 then
                          fail
                            "expected resolver to be called twice (cache miss), \
                             got %d"
                            call_count)))));
    Alcotest.test_case "--rebuild busts cache and re-evals unconditionally"
      `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                with_temp_dir "epi-cache-rebuild" (fun test_dir ->
                    with_counting_resolver ~extra_env ~test_dir
                      (fun ~extra_env ~resolver_log ->
                        let result1 =
                          run_cli_with_env ~bin ~state_dir ~extra_env
                            [ "launch"; "rebuild-test"; "--target"; ".#dev" ]
                        in
                        assert_success ~context:"rebuild first up" result1;
                        let entry = find_state_runtime ~state_dir "rebuild-test" in
                        let hypervisor_pid =
                          match entry with
                          | Some (Some pid, _, _, _, _, _, _) -> pid
                          | _ -> fail "expected pid after first up"
                        in
                        let passt_pid =
                          match entry with
                          | Some (_, _, _, Some pid, _, _, _) -> pid
                          | _ -> fail "expected passt_pid after first up"
                        in
                        terminate_pid hypervisor_pid;
                        terminate_pid passt_pid;
                        let _ = wait_for_pid_to_die ~attempts:20 hypervisor_pid in
                        let result2 =
                          run_cli_with_env ~bin ~state_dir ~extra_env
                            [ "launch"; "rebuild-test"; "--target"; ".#dev"; "--rebuild" ]
                        in
                        assert_success ~context:"rebuild second up" result2;
                        let call_count = count_resolver_calls resolver_log in
                        if call_count <> 2 then
                          fail
                            "expected resolver to be called twice (rebuild), got %d"
                            call_count)))));
  ]
