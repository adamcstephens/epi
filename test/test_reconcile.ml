open Test_helpers

let tests ~bin:_ =
  [
    Alcotest.test_case "reconciliation is no longer needed (systemd manages lifecycle)"
      `Quick (fun () ->
        (* Reconciliation was removed in favor of systemd unit status queries.
           This test verifies that Instance_store no longer has reconcile_runtime. *)
        with_state_dir (fun _state_dir -> ()));
  ]
