open Test_helpers
open Mock_runtime

let tests ~bin =
  [
    Alcotest.test_case "creates valid user-data and meta-data with correct content"
      `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                let result =
                  run_cli_with_env ~bin ~state_dir ~extra_env
                    [ "up"; "seed-test"; "--target"; ".#dev" ]
                in
                assert_success ~context:"seed iso up" result;
                let cidata_dir =
                  Filename.concat (Filename.concat state_dir "seed-test") "cidata"
                in
                let user_data_path =
                  Filename.concat cidata_dir "user-data"
                in
                let meta_data_path =
                  Filename.concat cidata_dir "meta-data"
                in
                if not (Sys.file_exists user_data_path) then
                  fail "user-data file was not created";
                if not (Sys.file_exists meta_data_path) then
                  fail "meta-data file was not created";
                let user_data = read_file user_data_path in
                let meta_data = read_file meta_data_path in
                assert_contains ~context:"user-data cloud-config header"
                  user_data "#cloud-config";
                assert_contains ~context:"user-data users section" user_data
                  "users:";
                assert_contains ~context:"user-data wheel group" user_data
                  "groups: wheel";
                assert_contains ~context:"user-data sudo" user_data
                  "sudo: ALL=(ALL) NOPASSWD:ALL";
                assert_contains ~context:"user-data shell" user_data
                  "shell: /run/current-system/sw/bin/bash";
                assert_contains ~context:"user-data disable_root" user_data
                  "disable_root: false";
                assert_contains ~context:"meta-data instance-id" meta_data
                  "instance-id: seed-test";
                assert_contains ~context:"meta-data local-hostname" meta_data
                  "local-hostname: seed-test")));
    Alcotest.test_case "SSH keys are read from ~/.ssh/*.pub and included in user-data"
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
                        [ "up"; "ssh-key-test"; "--target"; ".#dev" ]
                    in
                    assert_success ~context:"ssh key up" result;
                    let user_data_path =
                      Filename.concat
                        (Filename.concat
                           (Filename.concat state_dir "ssh-key-test")
                           "cidata")
                        "user-data"
                    in
                    if not (Sys.file_exists user_data_path) then
                      fail "user-data file was not created";
                    let user_data = read_file user_data_path in
                    assert_contains ~context:"user-data ssh_authorized_keys"
                      user_data "ssh_authorized_keys:";
                    assert_contains ~context:"user-data ed25519 key" user_data
                      "ssh-ed25519 AAAAC3test testkey@host";
                    assert_contains ~context:"user-data rsa key" user_data
                      "ssh-rsa AAAAB3test testkey2@host"))));
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
                        [ "up"; "no-ssh-test"; "--target"; ".#dev" ]
                    in
                    assert_success ~context:"no ssh keys up" result;
                    let _, _, stderr = result in
                    assert_contains ~context:"no ssh keys warning" stderr
                      "no SSH public keys found";
                    let user_data_path =
                      Filename.concat
                        (Filename.concat
                           (Filename.concat state_dir "no-ssh-test")
                           "cidata")
                        "user-data"
                    in
                    if not (Sys.file_exists user_data_path) then
                      fail "user-data file was not created";
                    let user_data = read_file user_data_path in
                    if contains user_data "ssh_authorized_keys" then
                      fail
                        "ssh_authorized_keys should be omitted when no keys \
                         found"))));
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
                    [ "up"; "no-genisoimage"; "--target"; ".#dev" ]
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
                    [ "up"; "disk-test"; "--target"; ".#dev" ]
                in
                assert_success ~context:"seed iso disk arg up" result;
                let launch_contents =
                  if Sys.file_exists launch_log then read_file launch_log
                  else ""
                in
                assert_contains ~context:"seed iso disk arg" launch_contents
                  "cidata.iso,readonly=on";
                assert_contains ~context:"passt net arg" launch_contents
                  "--net vhost_user=true,socket=")));
    Alcotest.test_case
      "configured user produces cloud-init with only SSH keys, no groups/sudo/shell"
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
                        [ "up"; "configured-test"; "--target"; ".#user-configured" ]
                    in
                    assert_success ~context:"configured user up" result;
                    let user_data_path =
                      Filename.concat
                        (Filename.concat
                           (Filename.concat state_dir "configured-test")
                           "cidata")
                        "user-data"
                    in
                    if not (Sys.file_exists user_data_path) then
                      fail "user-data file was not created";
                    let user_data = read_file user_data_path in
                    assert_contains ~context:"configured user ssh keys"
                      user_data "ssh_authorized_keys:";
                    assert_contains ~context:"configured user ssh key value"
                      user_data "ssh-ed25519 AAAAC3test testkey@host";
                    if contains user_data "groups: wheel" then
                      fail
                        "configured user cloud-init should not contain 'groups: \
                         wheel'";
                    if contains user_data "sudo:" then
                      fail
                        "configured user cloud-init should not contain 'sudo:'";
                    if contains user_data "shell:" then
                      fail
                        "configured user cloud-init should not contain 'shell:'"))));
    Alcotest.test_case
      "unconfigured user produces full cloud-init with groups/sudo/shell"
      `Quick (fun () ->
        with_mock_runtime (fun ~extra_env ~launch_log:_ ~disk:_ ->
            with_state_dir (fun state_dir ->
                let result =
                  run_cli_with_env ~bin ~state_dir ~extra_env
                    [ "up"; "unconfigured-test"; "--target"; ".#dev" ]
                in
                assert_success ~context:"unconfigured user up" result;
                let user_data_path =
                  Filename.concat
                    (Filename.concat
                       (Filename.concat state_dir "unconfigured-test")
                       "cidata")
                    "user-data"
                in
                if not (Sys.file_exists user_data_path) then
                  fail "user-data file was not created";
                let user_data = read_file user_data_path in
                assert_contains ~context:"unconfigured user groups" user_data
                  "groups: wheel";
                assert_contains ~context:"unconfigured user sudo" user_data
                  "sudo: ALL=(ALL) NOPASSWD:ALL";
                assert_contains ~context:"unconfigured user shell" user_data
                  "shell: /run/current-system/sw/bin/bash")));
  ]
