open Test_helpers
open Mock_runtime

let tests ~bin =
  [
    Alcotest.test_case "provisions explicit and implicit default instances"
      `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log ~disk:_ ->
            with_state_dir (fun state_dir ->
                let explicit =
                  run_cli_with_env ~bin ~state_dir ~extra_env
                    [ "launch"; "dev-a"; "--target"; ".#dev-a" ]
                in
                assert_success ~context:"explicit up" explicit;
                let _, stdout_explicit, _ = explicit in
                assert_contains ~context:"explicit up output" stdout_explicit
                  "vm: resolving target=.#dev-a";
                assert_contains ~context:"explicit up output" stdout_explicit
                  "vm: evaluated target, building artifacts";
                assert_contains ~context:"explicit up output" stdout_explicit
                  "vm: starting VM instance=dev-a";
                assert_contains ~context:"explicit up output" stdout_explicit
                  "launch: provisioned instance=dev-a target=.#dev-a unit_id=";
                assert_contains ~context:"explicit up output" stdout_explicit
                  "serial=";
                let implicit =
                  run_cli_with_env ~bin ~state_dir ~extra_env
                    [ "launch"; "--target"; "github:org/repo#dev" ]
                in
                assert_success ~context:"implicit up" implicit;
                let _, stdout_implicit, _ = implicit in
                assert_contains ~context:"implicit up output" stdout_implicit
                  "launch: provisioned instance=default target=github:org/repo#dev \
                   unit_id=";
                let launch_contents =
                  if Sys.file_exists launch_log then read_file launch_log
                  else ""
                in
                assert_contains ~context:"launch invocation log" launch_contents
                  "--serial";
                assert_contains ~context:"launch invocation log" launch_contents
                  "socket=";
                let dev_a = find_state_runtime ~state_dir "dev-a" in
                (match dev_a with
                | Some (Some _, Some _, _, _, _) -> ()
                | _ ->
                    fail
                      "expected runtime metadata with unit_id for dev-a");
                let default = find_state_runtime ~state_dir "default" in
                (match default with
                | Some (Some _, Some _, _, _, _) -> ()
                | _ ->
                    fail
                      "expected runtime metadata with unit_id for default");
                let status_default =
                  run_cli_with_env ~bin ~state_dir ~extra_env [ "status" ]
                in
                assert_success ~context:"status default" status_default;
                let _, status_out, _ = status_default in
                assert_contains ~context:"status default output" status_out
                  "status: instance=default")));
    Alcotest.test_case "emits stage progress messages during provisioning"
      `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                let result =
                  run_cli_with_env ~bin ~state_dir ~extra_env
                    [ "launch"; "stage-test"; "--target"; ".#stage-test" ]
                in
                assert_success ~context:"stage progress up" result;
                let _, stdout, _ = result in
                assert_contains ~context:"stage: target evaluation start" stdout
                  "vm: resolving target=.#stage-test";
                assert_contains ~context:"stage: launch preparation start" stdout
                  "vm: evaluated target, building artifacts";
                assert_contains ~context:"stage: VM launch start" stdout
                  "vm: starting VM instance=stage-test";
                assert_contains ~context:"stage: provisioned message" stdout
                  "launch: provisioned instance=stage-test")));
    Alcotest.test_case "rejects invalid target formats with actionable errors"
      `Quick (fun () ->
        with_state_dir (fun state_dir ->
            let missing_separator =
              run_cli ~bin ~state_dir [ "launch"; "dev-a"; "--target"; "." ]
            in
            assert_failure ~context:"missing separator" missing_separator;
            let _, _, err1 = missing_separator in
            assert_contains ~context:"missing separator error" err1
              "--target must use <flake-ref>#<config-name>";
            let missing_config =
              run_cli ~bin ~state_dir [ "launch"; "dev-a"; "--target"; ".#" ]
            in
            assert_failure ~context:"missing config" missing_config;
            let _, _, err2 = missing_config in
            assert_contains ~context:"missing config error" err2
              "both flake reference and config name are required"));
    Alcotest.test_case "does not persist instance when provisioning fails"
      `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                let failing_env = ("EPI_FORCE_LAUNCH_FAIL", "1") :: extra_env in
                let failed =
                  run_cli_with_env ~bin ~state_dir ~extra_env:failing_env
                    [ "launch"; "qa-1"; "--target"; ".#qa" ]
                in
                assert_failure ~context:"failing up" failed;
                let _, _, err = failed in
                assert_contains ~context:"launch failure error" err
                  "VM launch failed";
                let listed =
                  run_cli_with_env ~bin ~state_dir ~extra_env [ "list" ]
                in
                assert_success ~context:"list after failed up" listed;
                let _, listed_out, _ = listed in
                if contains listed_out "qa-1" then
                  fail "instance was unexpectedly persisted after launch failure")));
    Alcotest.test_case "reports target resolution failures with target context"
      `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                let failed =
                  run_cli_with_env ~bin ~state_dir ~extra_env
                    [ "launch"; "dev-a"; "--target"; ".#fail-resolve" ]
                in
                assert_failure ~context:"target resolution failure" failed;
                let _, _, err = failed in
                assert_contains ~context:"resolution failure stage" err
                  "target resolution failed";
                assert_contains ~context:"resolution failure target" err
                  ".#fail-resolve")));
    Alcotest.test_case "validates launch inputs before VM launch"
      `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log ~disk:_ ->
            with_state_dir (fun state_dir ->
                let failed =
                  run_cli_with_env ~bin ~state_dir ~extra_env
                    [ "launch"; "dev-a"; "--target"; ".#missing-disk" ]
                in
                assert_failure ~context:"missing disk failure" failed;
                let _, _, err = failed in
                assert_contains ~context:"missing input stage" err
                  "descriptor validation failed";
                assert_contains ~context:"missing input error" err
                  "missing launch input: disk";
                let launch_contents =
                  if Sys.file_exists launch_log then read_file launch_log
                  else ""
                in
                if String.length launch_contents > 0 then
                  fail "cloud-hypervisor was invoked despite missing launch input")));
    Alcotest.test_case "rejects mixed mutable disk and target-built boot artifacts"
      `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log ~disk:_ ->
            with_state_dir (fun state_dir ->
                let failed =
                  run_cli_with_env ~bin ~state_dir ~extra_env
                    [ "launch"; "dev-a"; "--target"; ".#mutable-disk" ]
                in
                assert_failure ~context:"mutable disk coherence failure" failed;
                let _, _, err = failed in
                assert_contains ~context:"coherence validation stage" err
                  "descriptor validation failed";
                assert_contains ~context:"coherence validation message" err
                  "launch inputs are not coherent";
                assert_contains ~context:"coherence guidance" err
                  "fix target outputs";
                let launch_contents =
                  if Sys.file_exists launch_log then read_file launch_log
                  else ""
                in
                if String.length launch_contents > 0 then
                  fail
                    "cloud-hypervisor was invoked despite coherence validation \n\
                     failure")));
    Alcotest.test_case "uses target-provided cmdline when available"
      `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log ~disk:_ ->
            with_state_dir (fun state_dir ->
                let launched =
                  run_cli_with_env ~bin ~state_dir ~extra_env
                    [ "launch"; "dev-cmdline"; "--target"; ".#custom-cmdline" ]
                in
                assert_success ~context:"custom cmdline up" launched;
                let launch_contents =
                  if Sys.file_exists launch_log then read_file launch_log
                  else ""
                in
                assert_contains ~context:"custom cmdline launch args"
                  launch_contents "root=/dev/vda1")));
    Alcotest.test_case "reports disk lock conflicts with tracked owner metadata"
      `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk ->
            with_state_dir (fun state_dir ->
                let owner_up =
                  run_cli_with_env ~bin ~state_dir ~extra_env
                    [ "launch"; "dev-owner"; "--target"; ".#owner" ]
                in
                assert_success ~context:"owner up" owner_up;
                let owner_unit_id =
                  match find_state_runtime ~state_dir "dev-owner" with
                  | Some (Some unit_id, _, _, _, _) -> unit_id
                  | _ -> fail "missing owner runtime metadata"
                in
                let failing_env = ("EPI_FORCE_LOCK_FAIL", "1") :: extra_env in
                let failed =
                  run_cli_with_env ~bin ~state_dir ~extra_env:failing_env
                    [ "launch"; "qa-1"; "--target"; ".#qa" ]
                in
                assert_failure ~context:"lock failure" failed;
                let _, _, err = failed in
                assert_contains ~context:"lock conflict stage" err
                  "another running VM already holds disk lock";
                assert_contains ~context:"lock conflict owner" err
                  "owner=dev-owner";
                assert_contains ~context:"lock conflict unit_id" err
                  owner_unit_id;
                assert_contains ~context:"lock conflict disk" err disk)));
    Alcotest.test_case "--console provisions and attaches to serial socket"
      `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log ~disk:_ ->
            with_state_dir (fun state_dir ->
                let wait_for_launch () =
                  let rec loop remaining =
                    if remaining <= 0 then
                      fail "mock launch log did not appear in time"
                    else if Sys.file_exists launch_log then
                      let contents = read_file launch_log in
                      if String.trim contents <> "" then ()
                      else
                        let _ = Unix.select [] [] [] 0.01 in
                        loop (remaining - 1)
                    else
                      let _ = Unix.select [] [] [] 0.01 in
                      loop (remaining - 1)
                  in
                  loop 400
                in
                let serial_socket =
                  Filename.concat
                    (Filename.concat state_dir "dev-a")
                    "serial.sock"
                in
                with_delayed_unix_socket_server ~socket_path:serial_socket
                  ~payload:"up-console\n" ~before_bind:wait_for_launch (fun () ->
                    let result =
                      run_cli_with_env ~bin ~state_dir ~extra_env
                        [ "launch"; "dev-a"; "--target"; ".#dev-a"; "--console" ]
                    in
                    assert_success ~context:"up console fresh" result;
                    let _, out, _ = result in
                    assert_contains ~context:"up console fresh stdout" out
                      "up-console";
                    let launch_contents =
                      if Sys.file_exists launch_log then read_file launch_log
                      else ""
                    in
                    assert_contains ~context:"up console launch invoked"
                      launch_contents "--serial"))));
    Alcotest.test_case "--console attaches to already running instance"
      `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log ~disk:_ ->
            with_state_dir (fun state_dir ->
                with_temp_dir "epi-up-console-running" (fun dir ->
                    let serial_socket = Filename.concat dir "dev-a.sock" in
                    with_unix_socket_server ~socket_path:serial_socket
                      ~payload:"up-console-running\n" (fun () ->
                        (* Write a state entry with a unit_id that maps to
                           an active systemd unit. Since we can't easily create
                           a real systemd unit in tests, we launch a real instance
                           first, then test the console attach path. *)
                        let launch_result =
                          run_cli_with_env ~bin ~state_dir ~extra_env
                            [ "launch"; "dev-a"; "--target"; ".#dev-a" ]
                        in
                        assert_success ~context:"launch for console test" launch_result;
                        (* Overwrite serial_socket to point to our mock server *)
                        let runtime_path =
                          Filename.concat
                            (Filename.concat state_dir "dev-a")
                            "runtime"
                        in
                        let runtime_content = read_file runtime_path in
                        let updated =
                          String.split_on_char '\n' runtime_content
                          |> List.map (fun line ->
                              if String.length line > 14
                                 && String.sub line 0 14 = "serial_socket="
                              then "serial_socket=" ^ serial_socket
                              else line)
                          |> String.concat "\n"
                        in
                        let oc = open_out runtime_path in
                        output_string oc updated;
                        close_out oc;
                        let result =
                          run_cli_with_env ~bin ~state_dir ~extra_env
                            [
                              "launch";
                              "dev-a";
                              "--target";
                              ".#dev-a";
                              "--console";
                            ]
                        in
                        assert_success ~context:"up console running" result;
                        let _, out, _ = result in
                        assert_contains ~context:"up console running stdout"
                          out "up-console-running";
                        let launch_contents =
                          if Sys.file_exists launch_log then
                            read_file launch_log
                          else ""
                        in
                        (* The launch log should only have one entry from the
                           first launch, not a second one *)
                        let lines =
                          String.split_on_char '\n' (String.trim launch_contents)
                          |> List.filter (fun s -> s <> "")
                        in
                        if List.length lines > 1 then
                          fail
                            "expected up --console to skip VM provisioning \
                             for running instance")))));
    Alcotest.test_case "over stale instance stops old slice"
      `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                let result =
                  run_cli_with_env ~bin ~state_dir ~extra_env
                    [ "launch"; "stale-relaunch"; "--target"; ".#dev" ]
                in
                assert_success ~context:"first up for stale" result;
                let old_unit_id =
                  match find_state_runtime ~state_dir "stale-relaunch" with
                  | Some (Some uid, _, _, _, _) -> uid
                  | _ -> fail "expected unit_id in state after first up"
                in
                (* Stop the VM service to make it stale *)
                ignore (stop_unit (vm_unit_name ~instance_name:"stale-relaunch"
                    ~unit_id:old_unit_id));
                let result2 =
                  run_cli_with_env ~bin ~state_dir ~extra_env
                    [ "launch"; "stale-relaunch"; "--target"; ".#dev" ]
                in
                assert_success ~context:"relaunch over stale" result2;
                let new_unit_id =
                  match find_state_runtime ~state_dir "stale-relaunch" with
                  | Some (Some uid, _, _, _, _) -> uid
                  | _ -> fail "expected unit_id in state after relaunch"
                in
                if old_unit_id = new_unit_id then
                  fail "expected a new unit_id after relaunch")));
    Alcotest.test_case "output includes the SSH port"
      `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                let result =
                  run_cli_with_env ~bin ~state_dir ~extra_env
                    [ "launch"; "ssh-port-output"; "--target"; ".#dev" ]
                in
                assert_success ~context:"ssh port output up" result;
                let _, stdout, _ = result in
                assert_contains ~context:"SSH port in up output" stdout
                  "SSH port:")));
  ]
