let contains s sub =
  let sl = String.length s and subl = String.length sub in
  let rec check i = i + subl <= sl &&
    (String.sub s i subl = sub || check (i + 1)) in
  check 0

let rec mkdir_p path =
  if path = "." || path = "/" || path = "" then ()
  else if Sys.file_exists path then ()
  else (mkdir_p (Filename.dirname path); Unix.mkdir path 0o755)

let write_hook dir name script =
  mkdir_p dir;
  let path = Filename.concat dir name in
  Test_helpers.write_file path script;
  Unix.chmod path 0o755

let tests =
  [
    Alcotest.test_case "all hook sources run on real VM" `Slow (fun () ->
      let instance_name = E2e_helpers.unique_name "e2e-hooks" in
      let target = ".#manual-test" in
      let latest_runtime = ref None in
      let project_hooks_dir = ".epi/hooks" in
      let cleanup () =
        (match !latest_runtime with
         | Some rt -> ignore (Epi.stop_instance ~instance_name rt)
         | None -> ());
        Epi.Instance_store.remove instance_name;
        (* clean up project hooks *)
        List.iter (fun sub ->
          let d = Filename.concat project_hooks_dir sub in
          if Sys.file_exists d then begin
            Array.iter (fun f -> Sys.remove (Filename.concat d f)) (Sys.readdir d);
            Unix.rmdir d
          end) ["post-launch.d"; "pre-stop.d"; "guest-init.d"]
      in
      Fun.protect ~finally:cleanup (fun () ->
        let instance_dir = Epi.Instance_store.instance_dir instance_name in
        let log_path = Filename.concat instance_dir "hook-order.log" in

        (* Set up project-level file hooks that log execution order *)
        let post_launch_dir = Filename.concat project_hooks_dir "post-launch.d" in
        write_hook post_launch_dir "00-project.sh"
          (Printf.sprintf "#!/bin/sh\necho project-post-launch >> %s\n" log_path);

        let pre_stop_dir = Filename.concat project_hooks_dir "pre-stop.d" in
        write_hook pre_stop_dir "00-project.sh"
          (Printf.sprintf "#!/bin/sh\necho project-pre-stop >> %s\n" log_path);

        let guest_init_dir = Filename.concat project_hooks_dir "guest-init.d" in
        write_hook guest_init_dir "00-project.sh"
          "#!/bin/sh\necho 'epi-hook: file-based guest-init ran'\n";

        (* Launch VM — guest-init file hooks are embedded in seed ISO *)
        let runtime =
          E2e_helpers.provision_and_wait ~instance_name ~target ~mount_paths:[] ()
        in
        latest_runtime := Some runtime;

        (* Verify guest-init: both file-based and nix hooks ran *)
        let journal =
          E2e_helpers.ssh_exec runtime
            [ "journalctl"; "-u"; "epi-init"; "--no-pager" ]
        in
        Alcotest.(check bool) "file-based guest-init hook ran" true
          (contains journal "running guest hook");
        Alcotest.(check bool) "nix guest-init hook ran" true
          (contains journal "nix guest hook");

        (* Execute post-launch hooks (file + nix) *)
        let canonical_target = Epi.Target.canonicalize_target target in
        let nix_hooks =
          match Epi.Target.load_descriptor_cache canonical_target with
          | Some desc -> desc.Epi.Target.hooks.post_launch
          | None -> Alcotest.fail "no cached descriptor"
        in
        let ssh_port =
          match runtime.Epi.Instance_store.ssh_port with
          | Some p -> p
          | None -> Alcotest.fail "no SSH port"
        in
        let username =
          match Sys.getenv_opt "USER" with Some u -> u | None -> "user"
        in
        let env = Epi.Hooks.{
          instance_name;
          ssh_port;
          ssh_key_path = runtime.Epi.Instance_store.ssh_key_path;
          ssh_user = username;
          state_dir = Epi.Instance_store.state_dir ();
        } in
        let hooks = Epi.Hooks.discover ~instance_name ~nix_hooks "post-launch" in
        Alcotest.(check bool) "post-launch has file + nix hooks"
          true (List.length hooks >= 2);
        (match Epi.Hooks.execute ~env hooks with
         | Ok () -> ()
         | Error msg -> Alcotest.fail ("post-launch failed: " ^ msg));

        (* Verify post-launch marker from nix hook *)
        let nix_marker =
          Filename.concat instance_dir "nix-post-launch-ran"
        in
        Alcotest.(check bool) "nix post-launch marker" true
          (Sys.file_exists nix_marker);

        (* Execute pre-stop hooks (file + nix) *)
        let nix_hooks_pre =
          match Epi.Target.load_descriptor_cache canonical_target with
          | Some desc -> desc.Epi.Target.hooks.pre_stop
          | None -> Alcotest.fail "no cached descriptor"
        in
        let hooks_pre = Epi.Hooks.discover ~instance_name ~nix_hooks:nix_hooks_pre "pre-stop" in
        Alcotest.(check bool) "pre-stop has file + nix hooks"
          true (List.length hooks_pre >= 2);
        (match Epi.Hooks.execute ~env hooks_pre with
         | Ok () -> ()
         | Error msg -> Alcotest.fail ("pre-stop failed: " ^ msg));

        (* Verify pre-stop marker from nix hook *)
        let nix_marker_pre =
          Filename.concat instance_dir "nix-pre-stop-ran"
        in
        Alcotest.(check bool) "nix pre-stop marker" true
          (Sys.file_exists nix_marker_pre);

        (* Verify ordering: project hooks ran before nix hooks *)
        let log_content =
          In_channel.with_open_text log_path In_channel.input_all
          |> String.trim
        in
        let lines = String.split_on_char '\n' log_content in
        Alcotest.(check (list string)) "hook execution order"
          ["project-post-launch"; "project-pre-stop"] lines));
  ]
