let () =
  Alcotest.run "epi-unit"
    [
      ("target", Test_target.tests);
      ("instance_store", Test_instance_store.tests);
    ]
