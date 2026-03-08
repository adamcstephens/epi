open Test_helpers

let tests ~bin =
  [
    Alcotest.test_case "reports not-running instances with guidance"
      `Quick (fun () ->
        with_state_dir (fun state_dir ->
            write_state_entry ~state_dir ~instance_name:"dev-a"
              ~target:".#dev-a" ();
            let result = run_cli ~bin ~state_dir [ "console"; "dev-a" ] in
            assert_failure ~context:"console not running" result;
            let _, _, err = result in
            assert_contains ~context:"console not running message" err
              "Instance 'dev-a' is not running";
            assert_contains ~context:"console not running guidance" err
              "epi launch dev-a --target"));
    Alcotest.test_case "attaches to running instance serial socket"
      `Quick (fun () ->
        with_state_dir (fun state_dir ->
            with_temp_dir "epi-console-running" (fun dir ->
                with_sleep_process (fun pid ->
                    let serial_socket = Filename.concat dir "dev-a.sock" in
                    with_unix_socket_server ~socket_path:serial_socket
                      ~payload:"console-connected\n" (fun () ->
                        write_state_entry ~state_dir ~instance_name:"dev-a"
                          ~target:".#dev-a" ~pid ~serial_socket
                          ~disk:"/tmp/dev-a.disk" ();
                        let result =
                          run_cli ~bin ~state_dir [ "console"; "dev-a" ]
                        in
                        assert_success ~context:"console running" result;
                        let _, out, _ = result in
                        assert_contains ~context:"console running stdout" out
                          "console-connected")))));
    Alcotest.test_case "writes serial output to capture file"
      `Quick (fun () ->
        with_state_dir (fun state_dir ->
            with_temp_dir "epi-console-capture" (fun dir ->
                with_sleep_process (fun pid ->
                    let serial_socket = Filename.concat dir "dev-a.sock" in
                    let capture_path = Filename.concat dir "capture.log" in
                    with_unix_socket_server ~socket_path:serial_socket
                      ~payload:"capture-connected\n" (fun () ->
                        write_state_entry ~state_dir ~instance_name:"dev-a"
                          ~target:".#dev-a" ~pid ~serial_socket
                          ~disk:"/tmp/dev-a.disk" ();
                        let result =
                          run_cli_with_env ~bin ~state_dir
                            ~extra_env:
                              [
                                ("EPI_CONSOLE_NON_INTERACTIVE", "1");
                                ("EPI_CONSOLE_CAPTURE_FILE", capture_path);
                              ]
                            [ "console"; "dev-a" ]
                        in
                        assert_success ~context:"console capture" result;
                        if not (Sys.file_exists capture_path) then
                          fail "console capture file was not created";
                        let captured = read_file capture_path in
                        assert_contains ~context:"console capture contents"
                          captured "capture-connected")))));
    Alcotest.test_case "reports unavailable serial endpoint for running instance"
      `Quick (fun () ->
        with_state_dir (fun state_dir ->
            with_sleep_process (fun pid ->
                write_state_entry ~state_dir ~instance_name:"dev-a"
                  ~target:".#dev-a" ~pid
                  ~serial_socket:"/tmp/epi-nonexistent.sock"
                  ~disk:"/tmp/disk.img" ();
                let result = run_cli ~bin ~state_dir [ "console"; "dev-a" ] in
                assert_failure ~context:"console unavailable endpoint" result;
                let _, _, err = result in
                assert_contains ~context:"console unavailable message" err
                  "Serial endpoint unavailable for 'dev-a'";
                assert_contains ~context:"console unavailable guidance" err
                  "Check VM runtime state for 'dev-a'")));
    Alcotest.test_case "non-interactive timeout reports guidance"
      `Quick (fun () ->
        with_state_dir (fun state_dir ->
            with_temp_dir "epi-console-timeout" (fun dir ->
                with_sleep_process (fun pid ->
                    let serial_socket = Filename.concat dir "dev-a.sock" in
                    with_hanging_unix_socket_server ~socket_path:serial_socket
                      ~hold_seconds:0.5 (fun () ->
                        write_state_entry ~state_dir ~instance_name:"dev-a"
                          ~target:".#dev-a" ~pid ~serial_socket
                          ~disk:"/tmp/dev-a.disk" ();
                        let result =
                          run_cli_with_env ~bin ~state_dir
                            ~extra_env:
                              [
                                ("EPI_CONSOLE_NON_INTERACTIVE", "1");
                                ("EPI_CONSOLE_TIMEOUT_SECONDS", "0.05");
                              ]
                            [ "console"; "dev-a" ]
                        in
                        assert_failure ~context:"console timeout" result;
                        let _, _, err = result in
                        assert_contains ~context:"console timeout message" err
                          "Console session timed out for 'dev-a'";
                        assert_contains ~context:"console timeout guidance" err
                          "EPI_CONSOLE_TIMEOUT_SECONDS")))));
  ]
