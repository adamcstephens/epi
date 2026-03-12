let () =
  let bin =
    if Array.length Sys.argv < 2 then
      failwith "Expected path to epi binary as argv[1]"
    else Sys.argv.(1)
  in
  let alcotest_argv =
    Array.append
      [| Sys.argv.(0) |]
      (Array.sub Sys.argv 2 (Array.length Sys.argv - 2))
  in
  Alcotest.run ~argv:alcotest_argv "epi"
    [
      ("launch", Test_up.tests ~bin);
      ("console", Test_console.tests ~bin);
      ("reconcile", Test_reconcile.tests ~bin);
      ("rm", Test_rm.tests ~bin);
      ("list", Test_list.tests ~bin);
      ("seed", Test_seed.tests ~bin);
      ("passt", Test_passt.tests ~bin);
      ("stop", Test_down.tests ~bin);
      ("mount", Test_mount.tests ~bin);
      ("misc", Test_misc.tests ~bin);
      ("exec", Test_exec.tests ~bin);
    ]
