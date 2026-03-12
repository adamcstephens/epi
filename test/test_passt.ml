open Test_helpers
open Mock_runtime

let tests ~bin =
  [
    Alcotest.test_case "EPI_PASST_BIN overrides passt binary path"
      `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_temp_dir "epi-passt-override" (fun custom_dir ->
                with_state_dir (fun state_dir ->
                    let custom_passt =
                      Filename.concat custom_dir "custom-passt.sh"
                    in
                    write_file custom_passt
                      "#!/usr/bin/env sh\n\
                       prev=\"\"\n\
                       for arg in \"$@\"; do\n\
                      \  if [ \"$prev\" = \"--socket\" ]; then\n\
                      \    touch \"$arg\"\n\
                      \  fi\n\
                      \  prev=\"$arg\"\n\
                       done\n\
                       exec sleep 30\n";
                    make_executable custom_passt;
                    let extra_env =
                      List.filter
                        (fun (key, _) ->
                          not (String.equal key "EPI_PASST_BIN"))
                        extra_env
                      @ [ ("EPI_PASST_BIN", custom_passt) ]
                    in
                    let result =
                      run_cli_with_env ~bin ~state_dir ~extra_env
                        [ "launch"; "passt-override"; "--target"; ".#dev" ]
                    in
                    assert_success ~context:"custom passt bin up" result))));
    Alcotest.test_case "missing passt binary produces a clear error"
      `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                let extra_env =
                  List.filter
                    (fun (key, _) -> not (String.equal key "EPI_PASST_BIN"))
                    extra_env
                  @ [ ("EPI_PASST_BIN", "nonexistent-passt-bin") ]
                in
                let result =
                  run_cli_with_env ~bin ~state_dir ~extra_env
                    [ "launch"; "no-passt"; "--target"; ".#dev" ]
                in
                assert_failure ~context:"missing passt" result;
                let _, _, err = result in
                assert_contains ~context:"passt error message" err "passt";
                assert_contains ~context:"passt EPI_PASST_BIN hint" err
                  "EPI_PASST_BIN")));
    Alcotest.test_case "is invoked with -t port:22 forwarding argument"
      `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_temp_dir "epi-passt-args-test" (fun dir ->
                let passt_log = Filename.concat dir "passt-args.log" in
                let passt = Filename.concat dir "passt.sh" in
                write_file passt
                  ("#!/usr/bin/env sh\n\
                    echo \"$*\" >> \"" ^ passt_log ^ "\"\n\
                    prev=\"\"\n\
                    for arg in \"$@\"; do\n\
                   \  if [ \"$prev\" = \"--socket\" ]; then\n\
                   \    touch \"$arg\"\n\
                   \  fi\n\
                   \  prev=\"$arg\"\n\
                    done\n\
                    exec sleep 30\n");
                make_executable passt;
                let extra_env =
                  List.filter
                    (fun (key, _) -> not (String.equal key "EPI_PASST_BIN"))
                    extra_env
                  @ [ ("EPI_PASST_BIN", passt) ]
                in
                with_state_dir (fun state_dir ->
                    let result =
                      run_cli_with_env ~bin ~state_dir ~extra_env
                        [ "launch"; "passt-args"; "--target"; ".#dev" ]
                    in
                    assert_success ~context:"passt args up" result;
                    let passt_args =
                      if Sys.file_exists passt_log then read_file passt_log
                      else ""
                    in
                    assert_contains ~context:"passt -t flag" passt_args "-t";
                    assert_contains ~context:"passt :22 target" passt_args ":22"))));
  ]
