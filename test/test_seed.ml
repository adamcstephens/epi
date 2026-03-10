open Test_helpers
open Mock_runtime

let read_epi_json ~state_dir instance_name =
  let path =
    Filename.concat
      (Filename.concat
         (Filename.concat state_dir instance_name)
         "epidata")
      "epi.json"
  in
  if not (Sys.file_exists path) then
    fail "epi.json was not created at %s" path;
  let content = read_file path in
  match Yojson.Basic.from_string content with
  | json -> json
  | exception Yojson.Json_error msg ->
      fail "epi.json is not valid JSON: %s" msg

let get_string key json =
  match json with
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`String s) -> s
      | _ -> fail "expected string field %S in epi.json" key)
  | _ -> fail "expected JSON object"

let get_assoc key json =
  match json with
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`Assoc _ as obj) -> obj
      | _ -> fail "expected object field %S in epi.json" key)
  | _ -> fail "expected JSON object"

let has_field key json =
  match json with
  | `Assoc fields -> List.assoc_opt key fields <> None
  | _ -> false

let tests ~bin =
  [
    Alcotest.test_case "creates valid epi.json with hostname and user data"
      `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                let result =
                  run_cli_with_env ~bin ~state_dir ~extra_env
                    [ "launch"; "seed-test"; "--target"; ".#dev" ]
                in
                assert_success ~context:"seed iso up" result;
                let json = read_epi_json ~state_dir "seed-test" in
                let hostname = get_string "hostname" json in
                if hostname <> "seed-test" then
                  fail "expected hostname 'seed-test', got %S" hostname;
                let user = get_assoc "user" json in
                let _name = get_string "name" user in
                if not (has_field "uid" user) then
                  fail "expected uid field for unconfigured user")));
    Alcotest.test_case "SSH keys are included in epi.json user.ssh_authorized_keys"
      `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                with_temp_dir "epi-ssh-key-test" (fun ssh_dir ->
                    write_file
                      (Filename.concat ssh_dir "id_ed25519.pub")
                      "ssh-ed25519 AAAAC3test testkey@host";
                    write_file
                      (Filename.concat ssh_dir "id_rsa.pub")
                      "ssh-rsa AAAAB3test testkey2@host";
                    let extra_env =
                      ("EPI_SSH_DIR", ssh_dir) :: extra_env
                    in
                    let result =
                      run_cli_with_env ~bin ~state_dir ~extra_env
                        [ "launch"; "ssh-key-test"; "--target"; ".#dev" ]
                    in
                    assert_success ~context:"ssh key up" result;
                    let json = read_epi_json ~state_dir "ssh-key-test" in
                    let user = get_assoc "user" json in
                    if not (has_field "ssh_authorized_keys" user) then
                      fail "expected ssh_authorized_keys in epi.json";
                    let content = read_file
                      (Filename.concat
                        (Filename.concat
                           (Filename.concat state_dir "ssh-key-test")
                           "epidata")
                        "epi.json")
                    in
                    assert_contains ~context:"ed25519 key in epi.json"
                      content "ssh-ed25519 AAAAC3test testkey@host";
                    assert_contains ~context:"rsa key in epi.json"
                      content "ssh-rsa AAAAB3test testkey2@host"))));
    Alcotest.test_case "missing SSH keys produce a warning but don't fail provisioning"
      `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                with_temp_dir "epi-no-ssh-test" (fun empty_ssh_dir ->
                    let extra_env =
                      ("EPI_SSH_DIR", empty_ssh_dir) :: extra_env
                    in
                    let result =
                      run_cli_with_env ~bin ~state_dir ~extra_env
                        [ "launch"; "no-ssh-test"; "--target"; ".#dev" ]
                    in
                    assert_success ~context:"no ssh keys up" result;
                    let _, _, stderr = result in
                    assert_contains ~context:"no ssh keys warning" stderr
                      "no SSH public keys found";
                    let json = read_epi_json ~state_dir "no-ssh-test" in
                    let user = get_assoc "user" json in
                    (* generated key should still be present *)
                    if not (has_field "ssh_authorized_keys" user) then
                      fail "expected generated key in ssh_authorized_keys"))));
    Alcotest.test_case "missing genisoimage produces a clear error"
      `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                let extra_env =
                  List.filter
                    (fun (key, _) ->
                      not (String.equal key "EPI_GENISOIMAGE_BIN"))
                    extra_env
                  @ [ ("EPI_GENISOIMAGE_BIN", "nonexistent-genisoimage-bin") ]
                in
                let result =
                  run_cli_with_env ~bin ~state_dir ~extra_env
                    [ "launch"; "no-genisoimage"; "--target"; ".#dev" ]
                in
                assert_failure ~context:"missing genisoimage" result;
                let _, _, err = result in
                assert_contains ~context:"genisoimage error message" err
                  "genisoimage not found";
                assert_contains ~context:"genisoimage cdrkit hint" err
                  "cdrkit")));
    Alcotest.test_case "seed ISO is passed as --disk argument to cloud-hypervisor"
      `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log ~disk:_ ->
            with_state_dir (fun state_dir ->
                let result =
                  run_cli_with_env ~bin ~state_dir ~extra_env
                    [ "launch"; "disk-test"; "--target"; ".#dev" ]
                in
                assert_success ~context:"seed iso disk arg up" result;
                let launch_contents =
                  if Sys.file_exists launch_log then read_file launch_log
                  else ""
                in
                assert_contains ~context:"seed iso disk arg" launch_contents
                  "epidata.iso,readonly=on";
                assert_contains ~context:"passt net arg" launch_contents
                  "--net vhost_user=true,socket=")));
    Alcotest.test_case
      "configured user produces epi.json without uid/groups/sudo"
      `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                with_temp_dir "epi-configured-user-test" (fun ssh_dir ->
                    write_file
                      (Filename.concat ssh_dir "id_ed25519.pub")
                      "ssh-ed25519 AAAAC3test testkey@host";
                    let extra_env =
                      ("EPI_SSH_DIR", ssh_dir) :: extra_env
                    in
                    let result =
                      run_cli_with_env ~bin ~state_dir ~extra_env
                        [ "launch"; "configured-test"; "--target"; ".#user-configured" ]
                    in
                    assert_success ~context:"configured user up" result;
                    let json = read_epi_json ~state_dir "configured-test" in
                    let user = get_assoc "user" json in
                    if has_field "uid" user then
                      fail "configured user epi.json should not contain uid"))));
    Alcotest.test_case
      "unconfigured user produces epi.json with uid"
      `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                let result =
                  run_cli_with_env ~bin ~state_dir ~extra_env
                    [ "launch"; "unconfigured-test"; "--target"; ".#dev" ]
                in
                assert_success ~context:"unconfigured user up" result;
                let json = read_epi_json ~state_dir "unconfigured-test" in
                let user = get_assoc "user" json in
                if not (has_field "uid" user) then
                  fail "unconfigured user epi.json should contain uid")));
  ]
