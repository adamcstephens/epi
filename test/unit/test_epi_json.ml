let with_temp_dir prefix f =
  let base =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (prefix ^ string_of_int (Unix.getpid ()))
  in
  let rec find_free n =
    let candidate = if n = 0 then base else base ^ "-" ^ string_of_int n in
    if Sys.file_exists candidate then find_free (n + 1) else candidate
  in
  let dir = find_free 0 in
  Unix.mkdir dir 0o755;
  let rec remove_tree path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Sys.readdir path
        |> Array.iter (fun name -> remove_tree (Filename.concat path name));
        Unix.rmdir path)
      else Sys.remove path
  in
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () -> f dir)

let parse json_str = Yojson.Basic.from_string json_str

let get_string key = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`String s) -> s
      | _ -> Alcotest.fail ("expected string field: " ^ key))
  | _ -> Alcotest.fail "expected JSON object"

let get_int key = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`Int i) -> i
      | _ -> Alcotest.fail ("expected int field: " ^ key))
  | _ -> Alcotest.fail "expected JSON object"

let get_assoc key = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`Assoc _ as obj) -> obj
      | _ -> Alcotest.fail ("expected object field: " ^ key))
  | _ -> Alcotest.fail "expected JSON object"

let has_field key = function
  | `Assoc fields -> List.assoc_opt key fields <> None
  | _ -> false

let get_string_list key = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`List items) ->
          List.map
            (function
              | `String s -> s | _ -> Alcotest.fail "expected string in list")
            items
      | _ -> Alcotest.fail ("expected list field: " ^ key))
  | _ -> Alcotest.fail "expected JSON object"

let tests =
  [
    Alcotest.test_case "new user gets uid" `Quick (fun () ->
        let json_str =
          Vm_launch.generate_epi_json ~instance_name:"test-vm"
            ~username:"testuser"
            ~ssh_keys:[ "ssh-ed25519 AAAA testkey" ]
            ~user_exists:false ~host_uid:1000 ~mount_paths:[]
        in
        let json = parse json_str in
        Alcotest.(check string)
          "hostname" "test-vm"
          (get_string "hostname" json);
        let user = get_assoc "user" json in
        Alcotest.(check string) "username" "testuser" (get_string "name" user);
        Alcotest.(check int) "uid" 1000 (get_int "uid" user));
    Alcotest.test_case "configured user omits uid" `Quick (fun () ->
        let json_str =
          Vm_launch.generate_epi_json ~instance_name:"test-vm"
            ~username:"testuser"
            ~ssh_keys:[ "ssh-ed25519 AAAA testkey" ]
            ~user_exists:true ~host_uid:1000 ~mount_paths:[]
        in
        let json = parse json_str in
        let user = get_assoc "user" json in
        if has_field "uid" user then
          Alcotest.fail "configured user should not have uid");
    Alcotest.test_case "no keys omits ssh_authorized_keys" `Quick (fun () ->
        let json_str =
          Vm_launch.generate_epi_json ~instance_name:"test-vm"
            ~username:"testuser" ~ssh_keys:[] ~user_exists:false ~host_uid:1000
            ~mount_paths:[]
        in
        let json = parse json_str in
        let user = get_assoc "user" json in
        if has_field "ssh_authorized_keys" user then
          Alcotest.fail "no keys should omit ssh_authorized_keys");
    Alcotest.test_case "keys included in ssh_authorized_keys" `Quick (fun () ->
        let keys = [ "ssh-ed25519 AAAA key1"; "ssh-rsa BBBB key2" ] in
        let json_str =
          Vm_launch.generate_epi_json ~instance_name:"test-vm"
            ~username:"testuser" ~ssh_keys:keys ~user_exists:false
            ~host_uid:1000 ~mount_paths:[]
        in
        let json = parse json_str in
        let user = get_assoc "user" json in
        let found_keys = get_string_list "ssh_authorized_keys" user in
        Alcotest.(check (list string)) "ssh keys" keys found_keys);
    Alcotest.test_case "mounts included when present" `Quick (fun () ->
        let paths = [ "/home/user/project"; "/data/shared" ] in
        let json_str =
          Vm_launch.generate_epi_json ~instance_name:"test-vm"
            ~username:"testuser" ~ssh_keys:[] ~user_exists:false ~host_uid:1000
            ~mount_paths:paths
        in
        let json = parse json_str in
        let found_mounts = get_string_list "mounts" json in
        Alcotest.(check (list string)) "mounts" paths found_mounts);
    Alcotest.test_case "mounts omitted when empty" `Quick (fun () ->
        let json_str =
          Vm_launch.generate_epi_json ~instance_name:"test-vm"
            ~username:"testuser" ~ssh_keys:[] ~user_exists:false ~host_uid:1000
            ~mount_paths:[]
        in
        let json = parse json_str in
        if has_field "mounts" json then
          Alcotest.fail "mounts should be omitted when empty");
    Alcotest.test_case "read_ssh_public_keys reads .pub files" `Quick (fun () ->
        with_temp_dir "epi-ssh-test" (fun ssh_dir ->
            let write path content =
              let oc = open_out path in
              output_string oc content;
              close_out oc
            in
            write
              (Filename.concat ssh_dir "id_ed25519.pub")
              "ssh-ed25519 AAAA testkey@host";
            write
              (Filename.concat ssh_dir "id_rsa.pub")
              "ssh-rsa BBBB testkey2@host";
            let old_env = Sys.getenv_opt "EPI_SSH_DIR" in
            Unix.putenv "EPI_SSH_DIR" ssh_dir;
            Fun.protect
              ~finally:(fun () ->
                match old_env with
                | Some v -> Unix.putenv "EPI_SSH_DIR" v
                | None -> Unix.putenv "EPI_SSH_DIR" "")
              (fun () ->
                let keys = Vm_launch.read_ssh_public_keys () in
                Alcotest.(check int) "key count" 2 (List.length keys);
                let has k = List.exists (fun s -> String.equal s k) keys in
                Alcotest.(check bool)
                  "ed25519 key" true
                  (has "ssh-ed25519 AAAA testkey@host");
                Alcotest.(check bool)
                  "rsa key" true
                  (has "ssh-rsa BBBB testkey2@host"))));
    Alcotest.test_case "read_ssh_public_keys handles empty dir" `Quick
      (fun () ->
        with_temp_dir "epi-ssh-empty" (fun ssh_dir ->
            let old_env = Sys.getenv_opt "EPI_SSH_DIR" in
            Unix.putenv "EPI_SSH_DIR" ssh_dir;
            Fun.protect
              ~finally:(fun () ->
                match old_env with
                | Some v -> Unix.putenv "EPI_SSH_DIR" v
                | None -> Unix.putenv "EPI_SSH_DIR" "")
              (fun () ->
                let keys = Vm_launch.read_ssh_public_keys () in
                Alcotest.(check int) "key count" 0 (List.length keys))));
  ]
