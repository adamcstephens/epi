open Test_helpers
open Mock_runtime

let with_systemd_mock_instance ~extra_env ~state_dir ~instance_name
    ~serial_socket f =
  let unit_id = Printf.sprintf "test%d" (Unix.getpid ()) in
  let escaped = escape_unit_name instance_name in
  let vm_unit = Printf.sprintf "epi-%s_%s_vm" escaped unit_id in
  let mock_systemd_dir = List.assoc "EPI_MOCK_SYSTEMD_DIR" extra_env in
  let pid_file = Filename.concat mock_systemd_dir (vm_unit ^ ".pid") in
  let sleep_pid =
    match Unix.fork () with
    | 0 -> Unix.execvp "sleep" [| "sleep"; "30" |]
    | pid -> pid
  in
  write_file pid_file (string_of_int sleep_pid);
  write_state_entry ~state_dir ~instance_name ~target:".#test" ~unit_id
    ~serial_socket ~disk:"/tmp/test.disk" ~ssh_key_path:"/tmp/test_key" ();
  Fun.protect
    ~finally:(fun () ->
      (try Unix.kill sleep_pid Sys.sigterm with Unix.Unix_error _ -> ());
      (try ignore (Unix.waitpid [ Unix.WNOHANG ] sleep_pid)
       with Unix.Unix_error (Unix.ECHILD, _, _) -> ());
      if Sys.file_exists pid_file then Sys.remove pid_file)
    (fun () -> f ())

let tests ~bin =
  [
    Alcotest.test_case "reports not-running instances with guidance" `Quick
      (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                write_state_entry ~state_dir ~instance_name:"dev-a"
                  ~target:".#dev-a" ();
                let result =
                  run_cli_with_env ~bin ~state_dir ~extra_env
                    [ "console"; "dev-a" ]
                in
                assert_failure ~context:"console not running" result;
                let _, _, err = result in
                assert_contains ~context:"console not running message" err
                  "Instance 'dev-a' is not running";
                assert_contains ~context:"console not running guidance" err
                  "epi launch dev-a --target")));
    Alcotest.test_case "attaches to running instance serial socket" `Quick
      (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                with_temp_dir "epi-console-running" (fun dir ->
                    let serial_socket = Filename.concat dir "dev-a.sock" in
                    with_unix_socket_server ~socket_path:serial_socket
                      ~payload:"console-connected\n" (fun () ->
                        with_systemd_mock_instance ~extra_env ~state_dir
                          ~instance_name:"dev-a" ~serial_socket (fun () ->
                            let result =
                              run_cli_with_env ~bin ~state_dir ~extra_env
                                [ "console"; "dev-a" ]
                            in
                            assert_success ~context:"console running" result;
                            let _, out, _ = result in
                            assert_contains ~context:"console running stdout"
                              out "console-connected"))))));
    Alcotest.test_case "writes serial output to capture file" `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                with_temp_dir "epi-console-capture" (fun dir ->
                    let serial_socket = Filename.concat dir "dev-a.sock" in
                    let capture_path = Filename.concat dir "capture.log" in
                    with_unix_socket_server ~socket_path:serial_socket
                      ~payload:"capture-connected\n" (fun () ->
                        with_systemd_mock_instance ~extra_env ~state_dir
                          ~instance_name:"dev-a" ~serial_socket (fun () ->
                            let result =
                              run_cli_with_env ~bin ~state_dir
                                ~extra_env:
                                  (extra_env
                                  @ [
                                      ("EPI_CONSOLE_NON_INTERACTIVE", "1");
                                      ("EPI_CONSOLE_CAPTURE_FILE", capture_path);
                                    ])
                                [ "console"; "dev-a" ]
                            in
                            assert_success ~context:"console capture" result;
                            if not (Sys.file_exists capture_path) then
                              fail "console capture file was not created";
                            let captured = read_file capture_path in
                            assert_contains ~context:"console capture contents"
                              captured "capture-connected"))))));
    Alcotest.test_case
      "reports unavailable serial endpoint for running instance" `Quick
      (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                with_systemd_mock_instance ~extra_env ~state_dir
                  ~instance_name:"dev-a"
                  ~serial_socket:"/tmp/epi-nonexistent.sock" (fun () ->
                    let result =
                      run_cli_with_env ~bin ~state_dir ~extra_env
                        [ "console"; "dev-a" ]
                    in
                    assert_failure ~context:"console unavailable endpoint"
                      result;
                    let _, _, err = result in
                    assert_contains ~context:"console unavailable message" err
                      "Serial endpoint unavailable for 'dev-a'";
                    assert_contains ~context:"console unavailable guidance" err
                      "Check VM runtime state for 'dev-a'"))));
    Alcotest.test_case "non-interactive timeout reports guidance" `Quick
      (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                with_temp_dir "epi-console-timeout" (fun dir ->
                    let serial_socket = Filename.concat dir "dev-a.sock" in
                    with_hanging_unix_socket_server ~socket_path:serial_socket
                      ~hold_seconds:0.5 (fun () ->
                        with_systemd_mock_instance ~extra_env ~state_dir
                          ~instance_name:"dev-a" ~serial_socket (fun () ->
                            let result =
                              run_cli_with_env ~bin ~state_dir
                                ~extra_env:
                                  (extra_env
                                  @ [
                                      ("EPI_CONSOLE_NON_INTERACTIVE", "1");
                                      ("EPI_CONSOLE_TIMEOUT_SECONDS", "0.05");
                                    ])
                                [ "console"; "dev-a" ]
                            in
                            assert_failure ~context:"console timeout" result;
                            let _, _, err = result in
                            assert_contains ~context:"console timeout message"
                              err "Console session timed out for 'dev-a'";
                            assert_contains ~context:"console timeout guidance"
                              err "EPI_CONSOLE_TIMEOUT_SECONDS"))))));
  ]
