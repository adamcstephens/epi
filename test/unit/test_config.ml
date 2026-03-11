let with_temp_dir prefix f =
  let base =
    Filename.concat (Filename.get_temp_dir_name ())
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

let write_file path content =
  Util.ensure_parent_dir path;
  let oc = open_out path in
  output_string oc content;
  close_out oc

let in_dir dir f =
  let old_cwd = Sys.getcwd () in
  Sys.chdir dir;
  Fun.protect ~finally:(fun () -> Sys.chdir old_cwd) f

let tests =
  [
    Alcotest.test_case "valid config with all keys" `Quick (fun () ->
        with_temp_dir "epi-config" (fun dir ->
            let config_path = Filename.concat dir ".epi/config.toml" in
            write_file config_path
              "target = \".#dev\"\nmounts = [\"/home/user/src\"]\ndisk_size = \"80G\"\n";
            in_dir dir (fun () ->
                match Config.load () with
                | Error e -> Alcotest.fail e
                | Ok c ->
                    Alcotest.(check (option string)) "target" (Some ".#dev") c.Config.target;
                    Alcotest.(check (option (list string))) "mounts"
                      (Some ["/home/user/src"]) c.Config.mounts;
                    Alcotest.(check (option string)) "disk_size" (Some "80G") c.Config.disk_size)));
    Alcotest.test_case "missing file returns empty" `Quick (fun () ->
        with_temp_dir "epi-config-miss" (fun dir ->
            in_dir dir (fun () ->
                match Config.load () with
                | Error e -> Alcotest.fail e
                | Ok c ->
                    Alcotest.(check (option string)) "target" None c.Config.target;
                    Alcotest.(check (option (list string))) "mounts" None c.Config.mounts;
                    Alcotest.(check (option string)) "disk_size" None c.Config.disk_size)));
    Alcotest.test_case "invalid TOML returns error with path" `Quick (fun () ->
        with_temp_dir "epi-config-bad" (fun dir ->
            let config_path = Filename.concat dir ".epi/config.toml" in
            write_file config_path "target = \n";
            in_dir dir (fun () ->
                match Config.load () with
                | Ok _ -> Alcotest.fail "expected error for invalid TOML"
                | Error msg ->
                    Alcotest.(check bool) "contains path"
                      true (Util.contains msg ".epi/config.toml"))));
    Alcotest.test_case "partial config" `Quick (fun () ->
        with_temp_dir "epi-config-partial" (fun dir ->
            let config_path = Filename.concat dir ".epi/config.toml" in
            write_file config_path "disk_size = \"50G\"\n";
            in_dir dir (fun () ->
                match Config.load () with
                | Error e -> Alcotest.fail e
                | Ok c ->
                    Alcotest.(check (option string)) "target" None c.Config.target;
                    Alcotest.(check (option (list string))) "mounts" None c.Config.mounts;
                    Alcotest.(check (option string)) "disk_size" (Some "50G") c.Config.disk_size)));
    Alcotest.test_case "config mount paths resolve against project root" `Quick (fun () ->
        with_temp_dir "epi-config-mounts" (fun dir ->
            let config_path = Filename.concat dir ".epi/config.toml" in
            write_file config_path "mounts = [\"src\", \"./data\"]\n";
            in_dir dir (fun () ->
                match Config.load () with
                | Error e -> Alcotest.fail e
                | Ok c ->
                    let expected = [
                      Filename.concat dir "src";
                      Filename.concat dir "data";
                    ] in
                    Alcotest.(check (option (list string))) "mounts" (Some expected) c.Config.mounts)));
    Alcotest.test_case "config mount tilde expansion" `Quick (fun () ->
        with_temp_dir "epi-config-tilde" (fun dir ->
            let config_path = Filename.concat dir ".epi/config.toml" in
            write_file config_path "mounts = [\"~/.config\"]\n";
            let home = Sys.getenv "HOME" in
            in_dir dir (fun () ->
                match Config.load () with
                | Error e -> Alcotest.fail e
                | Ok c ->
                    let expected = [Filename.concat home ".config"] in
                    Alcotest.(check (option (list string))) "mounts" (Some expected) c.Config.mounts)));
    Alcotest.test_case "config mount parent traversal" `Quick (fun () ->
        with_temp_dir "epi-config-parent" (fun dir ->
            let config_path = Filename.concat dir ".epi/config.toml" in
            write_file config_path "mounts = [\"../shared\"]\n";
            in_dir dir (fun () ->
                match Config.load () with
                | Error e -> Alcotest.fail e
                | Ok c ->
                    let expected = [Filename.concat dir "../shared"] in
                    Alcotest.(check (option (list string))) "mounts" (Some expected) c.Config.mounts)));
    Alcotest.test_case "CLI resolve_path absolute passthrough" `Quick (fun () ->
        let result = Config.resolve_path ~base:"/some/cwd" "/absolute/path" in
        Alcotest.(check string) "absolute" "/absolute/path" result);
    Alcotest.test_case "CLI resolve_path relative resolves against base" `Quick (fun () ->
        let result = Config.resolve_path ~base:"/home/user/project" "src" in
        Alcotest.(check string) "relative" "/home/user/project/src" result);
    Alcotest.test_case "CLI resolve_path tilde expansion" `Quick (fun () ->
        let home = Sys.getenv "HOME" in
        let result = Config.resolve_path ~base:"/some/cwd" "~/projects" in
        Alcotest.(check string) "tilde" (Filename.concat home "projects") result);
    Alcotest.test_case "merge: config values used when CLI args absent" `Quick (fun () ->
        let config : Config.t = {
          target = Some ".#dev"; mounts = Some ["/mnt/data"]; disk_size = Some "80G"
        } in
        match Config.merge ~cli_target:None ~cli_mounts:[] ~cli_disk_size:None config with
        | Error e -> Alcotest.fail e
        | Ok r ->
            Alcotest.(check string) "target" ".#dev" r.Config.resolved_target;
            Alcotest.(check (list string)) "mounts" ["/mnt/data"] r.Config.resolved_mounts;
            Alcotest.(check string) "disk_size" "80G" r.Config.resolved_disk_size);
    Alcotest.test_case "merge: CLI args override config values" `Quick (fun () ->
        let config : Config.t = {
          target = Some ".#dev"; mounts = Some ["/mnt/data"]; disk_size = Some "80G"
        } in
        match Config.merge ~cli_target:(Some ".#prod") ~cli_mounts:["/cli/mount"]
                ~cli_disk_size:(Some "20G") config with
        | Error e -> Alcotest.fail e
        | Ok r ->
            Alcotest.(check string) "target" ".#prod" r.Config.resolved_target;
            Alcotest.(check (list string)) "mounts" ["/cli/mount"] r.Config.resolved_mounts;
            Alcotest.(check string) "disk_size" "20G" r.Config.resolved_disk_size);
    Alcotest.test_case "merge: no target produces error mentioning config file" `Quick (fun () ->
        match Config.merge ~cli_target:None ~cli_mounts:[] ~cli_disk_size:None Config.empty with
        | Ok _ -> Alcotest.fail "expected error"
        | Error msg ->
            Alcotest.(check bool) "mentions config.toml"
              true (Util.contains msg "config.toml"));
    Alcotest.test_case "user_config_path: EPI_CONFIG_FILE takes precedence" `Quick (fun () ->
        let saved_epi = Sys.getenv_opt "EPI_CONFIG_FILE" in
        let saved_xdg = Sys.getenv_opt "XDG_CONFIG_HOME" in
        Fun.protect ~finally:(fun () ->
          (match saved_epi with Some v -> Unix.putenv "EPI_CONFIG_FILE" v | None -> Unix.putenv "EPI_CONFIG_FILE" "");
          if saved_epi = None then (try Unix.putenv "EPI_CONFIG_FILE" "" with _ -> ());
          (match saved_xdg with Some v -> Unix.putenv "XDG_CONFIG_HOME" v | None -> ()))
        (fun () ->
          Unix.putenv "EPI_CONFIG_FILE" "/custom/config.toml";
          Unix.putenv "XDG_CONFIG_HOME" "/xdg/home";
          match Config.user_config_path () with
          | Some p -> Alcotest.(check string) "path" "/custom/config.toml" p
          | None -> Alcotest.fail "expected Some"));
    Alcotest.test_case "user_config_path: XDG_CONFIG_HOME used when no EPI_CONFIG_FILE" `Quick (fun () ->
        with_temp_dir "epi-ucp" (fun _dir ->
          let save_env name =
            let v = Sys.getenv_opt name in
            (name, v)
          in
          let saved = List.map save_env ["EPI_CONFIG_FILE"; "XDG_CONFIG_HOME"] in
          Fun.protect ~finally:(fun () ->
            List.iter (fun (name, v) ->
              match v with Some s -> Unix.putenv name s | None -> Unix.putenv name "") saved)
          (fun () ->
            Unix.putenv "EPI_CONFIG_FILE" "";
            Unix.putenv "XDG_CONFIG_HOME" "/xdg/custom";
            match Config.user_config_path () with
            | Some p -> Alcotest.(check string) "path" "/xdg/custom/epi/config.toml" p
            | None -> Alcotest.fail "expected Some")));
    Alcotest.test_case "user_config_path: defaults to HOME/.config" `Quick (fun () ->
        with_temp_dir "epi-ucp-def" (fun _dir ->
          let save_env name =
            let v = Sys.getenv_opt name in
            (name, v)
          in
          let saved = List.map save_env ["EPI_CONFIG_FILE"; "XDG_CONFIG_HOME"] in
          Fun.protect ~finally:(fun () ->
            List.iter (fun (name, v) ->
              match v with Some s -> Unix.putenv name s | None -> Unix.putenv name "") saved)
          (fun () ->
            Unix.putenv "EPI_CONFIG_FILE" "";
            Unix.putenv "XDG_CONFIG_HOME" "";
            let home = Sys.getenv "HOME" in
            match Config.user_config_path () with
            | Some p -> Alcotest.(check string) "path"
                (Filename.concat (Filename.concat (Filename.concat home ".config") "epi") "config.toml") p
            | None -> Alcotest.fail "expected Some")));
    Alcotest.test_case "load_user: loads from EPI_CONFIG_FILE" `Quick (fun () ->
        with_temp_dir "epi-load-user" (fun dir ->
          let config_file = Filename.concat dir "user-config.toml" in
          write_file config_file "target = \".#user-target\"\n";
          let saved = Sys.getenv_opt "EPI_CONFIG_FILE" in
          Fun.protect ~finally:(fun () ->
            match saved with Some v -> Unix.putenv "EPI_CONFIG_FILE" v | None -> Unix.putenv "EPI_CONFIG_FILE" "")
          (fun () ->
            Unix.putenv "EPI_CONFIG_FILE" config_file;
            match Config.load_user () with
            | Error e -> Alcotest.fail e
            | Ok c -> Alcotest.(check (option string)) "target" (Some ".#user-target") c.Config.target)));
    Alcotest.test_case "load_user: error when EPI_CONFIG_FILE set but missing" `Quick (fun () ->
        let saved = Sys.getenv_opt "EPI_CONFIG_FILE" in
        Fun.protect ~finally:(fun () ->
          match saved with Some v -> Unix.putenv "EPI_CONFIG_FILE" v | None -> Unix.putenv "EPI_CONFIG_FILE" "")
        (fun () ->
          Unix.putenv "EPI_CONFIG_FILE" "/nonexistent/config.toml";
          match Config.load_user () with
          | Ok _ -> Alcotest.fail "expected error for missing explicit config"
          | Error msg ->
              Alcotest.(check bool) "mentions path" true (Util.contains msg "/nonexistent/config.toml")));
    Alcotest.test_case "load_user: empty config when default path missing" `Quick (fun () ->
        with_temp_dir "epi-load-user-miss" (fun dir ->
          let saved_epi = Sys.getenv_opt "EPI_CONFIG_FILE" in
          let saved_xdg = Sys.getenv_opt "XDG_CONFIG_HOME" in
          Fun.protect ~finally:(fun () ->
            (match saved_epi with Some v -> Unix.putenv "EPI_CONFIG_FILE" v | None -> Unix.putenv "EPI_CONFIG_FILE" "");
            (match saved_xdg with Some v -> Unix.putenv "XDG_CONFIG_HOME" v | None -> Unix.putenv "XDG_CONFIG_HOME" ""))
          (fun () ->
            Unix.putenv "EPI_CONFIG_FILE" "";
            Unix.putenv "XDG_CONFIG_HOME" dir;
            match Config.load_user () with
            | Error e -> Alcotest.fail e
            | Ok c ->
                Alcotest.(check (option string)) "target" None c.Config.target;
                Alcotest.(check (option (list string))) "mounts" None c.Config.mounts)));
    Alcotest.test_case "merge_configs: project overrides user" `Quick (fun () ->
        let user : Config.t = { target = Some ".#user"; mounts = Some ["/user/m"]; disk_size = Some "20G" } in
        let project : Config.t = { target = Some ".#proj"; mounts = None; disk_size = Some "60G" } in
        let merged = Config.merge_configs ~user ~project in
        Alcotest.(check (option string)) "target" (Some ".#proj") merged.Config.target;
        Alcotest.(check (option (list string))) "mounts" (Some ["/user/m"]) merged.Config.mounts;
        Alcotest.(check (option string)) "disk_size" (Some "60G") merged.Config.disk_size);
    Alcotest.test_case "three-tier: CLI > project > user" `Quick (fun () ->
        let user : Config.t = { target = Some ".#user"; mounts = Some ["/user/m"]; disk_size = Some "20G" } in
        let project : Config.t = { target = Some ".#proj"; mounts = None; disk_size = None } in
        let merged = Config.merge_configs ~user ~project in
        match Config.merge ~cli_target:(Some ".#cli") ~cli_mounts:[] ~cli_disk_size:None merged with
        | Error e -> Alcotest.fail e
        | Ok r ->
            Alcotest.(check string) "target from CLI" ".#cli" r.Config.resolved_target;
            Alcotest.(check (list string)) "mounts from user" ["/user/m"] r.Config.resolved_mounts;
            Alcotest.(check string) "disk_size from user" "20G" r.Config.resolved_disk_size);
  ]
