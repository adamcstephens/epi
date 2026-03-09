open Test_helpers

let tests ~bin =
  [
    Alcotest.test_case "fails with usage when no command given"
      `Quick (fun () ->
        with_state_dir (fun state_dir ->
            let result = run_cli ~bin ~state_dir [ "exec" ] in
            assert_failure ~context:"exec no args" result;
            let _, _, stderr = result in
            assert_contains ~context:"exec no args stderr" stderr
              "exec requires a command"));
    Alcotest.test_case "reports not-running for default instance"
      `Quick (fun () ->
        with_state_dir (fun state_dir ->
            let result =
              run_cli ~bin ~state_dir [ "exec"; "--"; "ls"; "/tmp" ]
            in
            assert_failure ~context:"exec not running" result;
            let _, _, stderr = result in
            assert_contains ~context:"exec not running stderr" stderr
              "not running"));
    Alcotest.test_case "reports not-running for named instance"
      `Quick (fun () ->
        with_state_dir (fun state_dir ->
            write_state_entry ~state_dir ~instance_name:"dev-a"
              ~target:".#dev-a" ();
            let result =
              run_cli ~bin ~state_dir [ "exec"; "dev-a"; "--"; "uname"; "-a" ]
            in
            assert_failure ~context:"exec named not running" result;
            let _, _, stderr = result in
            assert_contains ~context:"exec named not running stderr" stderr
              "not running"));
  ]
