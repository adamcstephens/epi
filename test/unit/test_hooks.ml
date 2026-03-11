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

let write_script path =
  let oc = open_out path in
  output_string oc "#!/bin/sh\ntrue\n";
  close_out oc;
  Unix.chmod path 0o755

let write_non_executable path =
  let oc = open_out path in
  output_string oc "#!/bin/sh\ntrue\n";
  close_out oc;
  Unix.chmod path 0o644

let mkdir_p path =
  let rec ensure path =
    if path = "." || path = "/" || path = "" then ()
    else if Sys.file_exists path then ()
    else (
      ensure (Filename.dirname path);
      Unix.mkdir path 0o755)
  in
  ensure path

let tests =
  [
    Alcotest.test_case "discover_scripts: empty dir" `Quick (fun () ->
        with_temp_dir "hooks-empty" (fun dir ->
            let scripts = Hooks.discover_scripts dir in
            Alcotest.(check int) "count" 0 (List.length scripts)));
    Alcotest.test_case "discover_scripts: nonexistent dir" `Quick (fun () ->
        let scripts = Hooks.discover_scripts "/tmp/nonexistent-hooks-dir" in
        Alcotest.(check int) "count" 0 (List.length scripts));
    Alcotest.test_case "discover_scripts: lexical order" `Quick (fun () ->
        with_temp_dir "hooks-order" (fun dir ->
            write_script (Filename.concat dir "02-second.sh");
            write_script (Filename.concat dir "01-first.sh");
            write_script (Filename.concat dir "03-third.sh");
            let scripts = Hooks.discover_scripts dir in
            Alcotest.(check int) "count" 3 (List.length scripts);
            Alcotest.(check bool) "first" true
              (String.ends_with ~suffix:"01-first.sh" (List.nth scripts 0));
            Alcotest.(check bool) "second" true
              (String.ends_with ~suffix:"02-second.sh" (List.nth scripts 1));
            Alcotest.(check bool) "third" true
              (String.ends_with ~suffix:"03-third.sh" (List.nth scripts 2))));
    Alcotest.test_case "discover_scripts: skips non-executable with warning" `Quick (fun () ->
        with_temp_dir "hooks-noexec" (fun dir ->
            write_script (Filename.concat dir "good.sh");
            write_non_executable (Filename.concat dir "bad.sh");
            let scripts = Hooks.discover_scripts dir in
            Alcotest.(check int) "count" 1 (List.length scripts);
            Alcotest.(check bool) "good.sh" true
              (String.ends_with ~suffix:"good.sh" (List.hd scripts))));
    Alcotest.test_case "discover_scripts: accepts any executable, skips dotfiles" `Quick (fun () ->
        with_temp_dir "hooks-nonsh" (fun dir ->
            write_script (Filename.concat dir "hook.sh");
            write_script (Filename.concat dir "setup-db");
            write_script (Filename.concat dir ".hidden");
            let scripts = Hooks.discover_scripts dir in
            Alcotest.(check int) "count" 2 (List.length scripts)));
    Alcotest.test_case "discover_scripts: ignores subdirectories" `Quick (fun () ->
        with_temp_dir "hooks-subdir" (fun dir ->
            write_script (Filename.concat dir "hook.sh");
            Unix.mkdir (Filename.concat dir "subdir") 0o755;
            let scripts = Hooks.discover_scripts dir in
            Alcotest.(check int) "count" 1 (List.length scripts)));
    Alcotest.test_case "discover_from_dir: top-level and instance" `Quick (fun () ->
        with_temp_dir "hooks-instance" (fun dir ->
            write_script (Filename.concat dir "all.sh");
            mkdir_p (Filename.concat dir "dev");
            write_script (Filename.concat dir "dev/specific.sh");
            mkdir_p (Filename.concat dir "staging");
            write_script (Filename.concat dir "staging/other.sh");
            let scripts = Hooks.discover_from_dir ~instance_name:"dev" dir in
            Alcotest.(check int) "count" 2 (List.length scripts);
            Alcotest.(check bool) "first is top-level" true
              (String.ends_with ~suffix:"all.sh" (List.nth scripts 0));
            Alcotest.(check bool) "second is instance" true
              (String.ends_with ~suffix:"dev/specific.sh" (List.nth scripts 1))));
    Alcotest.test_case "discover_from_dir: instance subdir ignored for other instance" `Quick (fun () ->
        with_temp_dir "hooks-other" (fun dir ->
            write_script (Filename.concat dir "all.sh");
            mkdir_p (Filename.concat dir "dev");
            write_script (Filename.concat dir "dev/specific.sh");
            let scripts = Hooks.discover_from_dir ~instance_name:"staging" dir in
            Alcotest.(check int) "count" 1 (List.length scripts)));
    Alcotest.test_case "discover: user then project layer ordering" `Quick (fun () ->
        with_temp_dir "hooks-layers" (fun dir ->
            let user_dir = Filename.concat dir "user/epi/hooks/post-launch.d" in
            let project_dir = Filename.concat dir "project/.epi/hooks/post-launch.d" in
            mkdir_p user_dir;
            mkdir_p project_dir;
            write_script (Filename.concat user_dir "user-hook.sh");
            write_script (Filename.concat project_dir "project-hook.sh");
            (* Override hook dirs via env *)
            let old_xdg = Sys.getenv_opt "XDG_CONFIG_HOME" in
            let old_cwd = Sys.getcwd () in
            Unix.putenv "XDG_CONFIG_HOME" (Filename.concat dir "user");
            Sys.chdir (Filename.concat dir "project");
            Fun.protect
              ~finally:(fun () ->
                (match old_xdg with
                 | Some v -> Unix.putenv "XDG_CONFIG_HOME" v
                 | None -> Unix.putenv "XDG_CONFIG_HOME" "");
                Sys.chdir old_cwd)
              (fun () ->
                let scripts = Hooks.discover ~instance_name:"default" "post-launch" in
                Alcotest.(check int) "count" 2 (List.length scripts);
                Alcotest.(check bool) "user first" true
                  (String.ends_with ~suffix:"user-hook.sh" (List.nth scripts 0));
                Alcotest.(check bool) "project second" true
                  (String.ends_with ~suffix:"project-hook.sh" (List.nth scripts 1)))));
    Alcotest.test_case "execute: env vars set" `Quick (fun () ->
        with_temp_dir "hooks-exec" (fun dir ->
            let script_path = Filename.concat dir "check-env" in
            let out_path = Filename.concat dir "output" in
            let oc = open_out script_path in
            Printf.fprintf oc "#!/bin/sh\necho \"$EPI_INSTANCE:$EPI_SSH_PORT:$EPI_SSH_USER\" > %s\n" out_path;
            close_out oc;
            Unix.chmod script_path 0o755;
            let env = Hooks.{
              instance_name = "dev";
              ssh_port = 12345;
              ssh_key_path = "/tmp/key";
              ssh_user = "alice";
              state_dir = "/tmp/state";
            } in
            let result = Hooks.execute ~env [script_path] in
            Alcotest.(check bool) "ok" true (Result.is_ok result);
            let content = In_channel.with_open_text out_path In_channel.input_all |> String.trim in
            Alcotest.(check string) "env output" "dev:12345:alice" content));
    Alcotest.test_case "execute: failure stops chain" `Quick (fun () ->
        with_temp_dir "hooks-fail" (fun dir ->
            let fail_script = Filename.concat dir "fail" in
            let oc = open_out fail_script in
            output_string oc "#!/bin/sh\nexit 1\n";
            close_out oc;
            Unix.chmod fail_script 0o755;
            let marker = Filename.concat dir "marker" in
            let ok_script = Filename.concat dir "ok" in
            let oc = open_out ok_script in
            Printf.fprintf oc "#!/bin/sh\ntouch %s\n" marker;
            close_out oc;
            Unix.chmod ok_script 0o755;
            let env = Hooks.{
              instance_name = "dev"; ssh_port = 1; ssh_key_path = "";
              ssh_user = "x"; state_dir = "";
            } in
            let result = Hooks.execute ~env [fail_script; ok_script] in
            Alcotest.(check bool) "error" true (Result.is_error result);
            Alcotest.(check bool) "second not run" false (Sys.file_exists marker)));
    Alcotest.test_case "execute: empty list is no-op" `Quick (fun () ->
        let env = Hooks.{
          instance_name = "dev"; ssh_port = 1; ssh_key_path = "";
          ssh_user = "x"; state_dir = "";
        } in
        let result = Hooks.execute ~env [] in
        Alcotest.(check bool) "ok" true (Result.is_ok result));
    Alcotest.test_case "discover_guest: collects from guest-init.d" `Quick (fun () ->
        with_temp_dir "hooks-guest" (fun dir ->
            let project_dir = Filename.concat dir "project/.epi/hooks/guest-init.d" in
            mkdir_p project_dir;
            write_script (Filename.concat project_dir "setup");
            let old_xdg = Sys.getenv_opt "XDG_CONFIG_HOME" in
            let old_cwd = Sys.getcwd () in
            Unix.putenv "XDG_CONFIG_HOME" (Filename.concat dir "user");
            Sys.chdir (Filename.concat dir "project");
            Fun.protect
              ~finally:(fun () ->
                (match old_xdg with
                 | Some v -> Unix.putenv "XDG_CONFIG_HOME" v
                 | None -> Unix.putenv "XDG_CONFIG_HOME" "");
                Sys.chdir old_cwd)
              (fun () ->
                let scripts = Hooks.discover_guest ~instance_name:"default" in
                Alcotest.(check int) "count" 1 (List.length scripts);
                Alcotest.(check bool) "is setup" true
                  (String.ends_with ~suffix:"setup" (List.hd scripts)))));
    Alcotest.test_case "discover: no dirs returns empty" `Quick (fun () ->
        with_temp_dir "hooks-nodirs" (fun dir ->
            let old_xdg = Sys.getenv_opt "XDG_CONFIG_HOME" in
            let old_cwd = Sys.getcwd () in
            Unix.putenv "XDG_CONFIG_HOME" (Filename.concat dir "user");
            Sys.chdir dir;
            Fun.protect
              ~finally:(fun () ->
                (match old_xdg with
                 | Some v -> Unix.putenv "XDG_CONFIG_HOME" v
                 | None -> Unix.putenv "XDG_CONFIG_HOME" "");
                Sys.chdir old_cwd)
              (fun () ->
                let scripts = Hooks.discover ~instance_name:"default" "post-launch" in
                Alcotest.(check int) "count" 0 (List.length scripts))));
  ]
