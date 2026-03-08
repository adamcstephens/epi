open Test_helpers

let tests ~bin =
  [
    Alcotest.test_case "clears stale runtime and keeps active runtime"
      `Quick (fun () ->
        with_state_dir (fun state_dir ->
            with_temp_dir "epi-reconcile-test" (fun dir ->
                with_sleep_process (fun live_pid ->
                    write_state_entry ~state_dir ~instance_name:"stale"
                      ~target:".#stale" ~pid:999_999
                      ~serial_socket:(Filename.concat dir "stale.sock")
                      ~disk:"/tmp/stale-disk.img" ();
                    write_state_entry ~state_dir ~instance_name:"live"
                      ~target:".#live" ~pid:live_pid
                      ~serial_socket:(Filename.concat dir "live.sock")
                      ~disk:"/tmp/live-disk.img" ();
                    let listed = run_cli ~bin ~state_dir [ "list" ] in
                    assert_success ~context:"list with reconciliation" listed;
                    let stale = find_state_runtime ~state_dir "stale" in
                    (match stale with
                    | Some (None, _, _, _, _, _, _) | None -> ()
                    | _ -> fail "expected stale runtime metadata to be cleared");
                    let live = find_state_runtime ~state_dir "live" in
                    match live with
                    | Some (Some pid, _, _, _, _, _, _) when pid = live_pid -> ()
                    | _ -> fail "expected live runtime metadata to remain active"))));
  ]
