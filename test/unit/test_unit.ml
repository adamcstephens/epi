let () =
  Alcotest.run "epi-unit"
    [
      ("target", Test_target.tests);
      ("instance_store", Test_instance_store.tests);
      ("vm_launch", Test_vm_launch.tests);
      ("epi_json", Test_epi_json.tests);
      ("cache", Test_cache.tests);
      ("provision", Test_provision.tests);
      ("provision_integration", Test_provision_integration.tests);
    ]
