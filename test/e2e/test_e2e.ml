let () =
  Alcotest.run "epi-e2e"
    [
      ("e2e-setup", Test_e2e_setup.tests);
      ("e2e-lifecycle", Test_lifecycle_e2e.tests);
      ("e2e-mount", Test_mount_e2e.tests);
      ("e2e-hooks", Test_hooks_e2e.tests);
    ]
