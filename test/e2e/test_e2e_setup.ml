let tests =
  [
    Alcotest.test_case "rebuild e2e target" `Slow (fun () ->
      let instance_name = E2e_helpers.unique_name "e2e-setup" in
      let target = ".#manual-test" in
      let runtime =
        E2e_helpers.provision_and_wait ~rebuild:true ~instance_name ~target
          ~mount_paths:[] ()
      in
      ignore (Epi.stop_instance ~instance_name runtime);
      Epi.Instance_store.remove instance_name);
  ]
