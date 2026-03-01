let cmd =
  Command.make ~summary:"A simple calculator."
    (let open Command.Std in
     let+ () = Arg.return () in
     ())
