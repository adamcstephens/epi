type console_error =
  | Instance_not_running of { instance_name : string }
  | Serial_endpoint_unavailable of {
      instance_name : string;
      endpoint : string;
      details : string;
    }
  | Console_capture_failed of {
      instance_name : string;
      capture_path : string;
      details : string;
    }
  | Console_session_timed_out of {
      instance_name : string;
      timeout_seconds : float;
    }

let rec write_all fd buffer offset length =
  if length = 0 then ()
  else
    let written = Unix.write fd buffer offset length in
    write_all fd buffer (offset + written) (length - written)

let rec connect_serial_socket socket endpoint attempts_remaining =
  try
    Unix.connect socket (Unix.ADDR_UNIX endpoint);
    Ok ()
  with
  | Unix.Unix_error ((Unix.ENOENT | Unix.ECONNREFUSED), _, _)
    when attempts_remaining > 0 ->
      let _ = Unix.select [] [] [] 0.05 in
      connect_serial_socket socket endpoint (attempts_remaining - 1)
  | Unix.Unix_error (error, _, _) -> Error (Unix.error_message error)

let attach_console ?(read_stdin = true) ?capture_path ?timeout_seconds
    ~instance_name runtime =
  let endpoint = runtime.Instance_store.serial_socket in
  let socket = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  let stdout_fd = Unix.descr_of_out_channel stdout in
  let stdin_fd = Unix.descr_of_in_channel stdin in
  let close_socket () = try Unix.close socket with Unix.Unix_error _ -> () in
  let write_capture capture_channel buffer read_bytes =
    output capture_channel buffer 0 read_bytes;
    flush capture_channel
  in
  let read_and_forward src dst capture_channel_opt =
    let buffer = Bytes.create 4096 in
    match Unix.read src buffer 0 (Bytes.length buffer) with
    | 0 -> `Eof
    | read_bytes ->
        write_all dst buffer 0 read_bytes;
        (match capture_channel_opt with
        | Some capture_channel ->
            write_capture capture_channel buffer read_bytes
        | None -> ());
        `Ok
  in
  let open_capture_channel capture =
    try Ok (open_out_gen [ Open_creat; Open_trunc; Open_wronly ] 0o644 capture)
    with Sys_error details ->
      Error
        (Console_capture_failed
           { instance_name; capture_path = capture; details })
  in
  let close_capture_channel channel_opt =
    match channel_opt with
    | Some channel -> close_out_noerr channel
    | None -> ()
  in
  match connect_serial_socket socket endpoint 40 with
  | Error details ->
      close_socket ();
      Error (Serial_endpoint_unavailable { instance_name; endpoint; details })
  | Ok () -> (
      let capture_channel_result =
        match capture_path with
        | Some capture -> open_capture_channel capture
        | None -> Ok stdout
      in
      match capture_channel_result with
      | Error _ as error ->
          close_socket ();
          error
      | Ok capture_channel -> (
          let capture_channel_opt =
            match capture_path with
            | Some _ -> Some capture_channel
            | None -> None
          in
          let read_timeout_seconds =
            match timeout_seconds with
            | Some value when value > 0.0 -> Some value
            | _ -> None
          in
          let deadline =
            match read_timeout_seconds with
            | Some seconds -> Some (Unix.gettimeofday () +. seconds)
            | None -> None
          in
          let saved_termios =
            if read_stdin && Unix.isatty stdin_fd then (
              let term = Unix.tcgetattr stdin_fd in
              Unix.tcsetattr stdin_fd Unix.TCSAFLUSH
                {
                  term with
                  Unix.c_echo = false;
                  Unix.c_icanon = false;
                  Unix.c_isig = false;
                  Unix.c_ixon = false;
                  Unix.c_vmin = 1;
                  Unix.c_vtime = 0;
                };
              Some term)
            else None
          in
          let restore_termios () =
            match saved_termios with
            | Some term -> Unix.tcsetattr stdin_fd Unix.TCSAFLUSH term
            | None -> ()
          in
          let saw_prefix = ref false in
          if read_stdin then
            Printf.printf "\r[console attached — ctrl-t q to detach]\n%!";
          try
            let rec loop read_stdin =
              let read_fds =
                if read_stdin then [ socket; stdin_fd ] else [ socket ]
              in
              let wait_timeout =
                match deadline with
                | None -> -1.0
                | Some deadline_time ->
                    let remaining = deadline_time -. Unix.gettimeofday () in
                    if remaining <= 0.0 then 0.0 else remaining
              in
              let ready, _, _ = Unix.select read_fds [] [] wait_timeout in
              if
                ready = []
                && match deadline with Some _ -> true | None -> false
              then
                raise
                  (Failure
                     (Printf.sprintf "console timeout reached after %.3fs"
                        (match read_timeout_seconds with
                        | Some seconds -> seconds
                        | None -> 0.0)));
              let read_stdin =
                if read_stdin && List.exists (( = ) stdin_fd) ready then (
                  let buf = Bytes.create 4096 in
                  match Unix.read stdin_fd buf 0 (Bytes.length buf) with
                  | 0 ->
                      Unix.shutdown socket Unix.SHUTDOWN_SEND;
                      false
                  | n ->
                      if !saw_prefix then (
                        saw_prefix := false;
                        if Bytes.get buf 0 = 'q' || Bytes.get buf 0 = 'Q' then
                          raise Exit;
                        write_all socket (Bytes.make 1 '\x14') 0 1);
                      let flush_from = ref 0 in
                      let i = ref 0 in
                      while !i < n do
                        if Bytes.get buf !i = '\x14' then
                          if !i + 1 < n then
                            if
                              Bytes.get buf (!i + 1) = 'q'
                              || Bytes.get buf (!i + 1) = 'Q'
                            then (
                              write_all socket buf !flush_from (!i - !flush_from);
                              raise Exit)
                            else i := !i + 1
                          else (
                            write_all socket buf !flush_from (!i - !flush_from);
                            saw_prefix := true;
                            flush_from := n;
                            i := n)
                        else i := !i + 1
                      done;
                      if !flush_from < n then
                        write_all socket buf !flush_from (n - !flush_from);
                      true)
                else read_stdin
              in
              let socket_open =
                if List.exists (( = ) socket) ready then
                  match
                    read_and_forward socket stdout_fd capture_channel_opt
                  with
                  | `Eof -> false
                  | `Ok -> true
                else true
              in
              if socket_open then loop read_stdin
            in
            loop read_stdin;
            restore_termios ();
            close_capture_channel capture_channel_opt;
            close_socket ();
            Ok ()
          with
          | Exit ->
              restore_termios ();
              close_capture_channel capture_channel_opt;
              close_socket ();
              Printf.printf "\r\n[console detached]\n%!";
              Ok ()
          | Failure message when Util.contains message "console timeout reached"
            ->
              restore_termios ();
              close_capture_channel capture_channel_opt;
              close_socket ();
              Error
                (Console_session_timed_out
                   {
                     instance_name;
                     timeout_seconds =
                       (match read_timeout_seconds with
                       | Some seconds -> seconds
                       | None -> 0.0);
                   })
          | Unix.Unix_error (error, _, _) ->
              restore_termios ();
              close_capture_channel capture_channel_opt;
              close_socket ();
              Error
                (Serial_endpoint_unavailable
                   {
                     instance_name;
                     endpoint;
                     details = Unix.error_message error;
                   })))

let pp_console_error = function
  | Instance_not_running { instance_name } ->
      Printf.sprintf
        "Instance '%s' is not running. Run `epi launch %s --target \
         <flake#config>` or `epi start %s` if the instance already exists."
        instance_name instance_name instance_name
  | Serial_endpoint_unavailable { instance_name; endpoint; details } ->
      Printf.sprintf
        "Serial endpoint unavailable for '%s' at %s: %s. Check VM runtime \
         state for '%s'."
        instance_name endpoint details instance_name
  | Console_capture_failed { instance_name; capture_path; details } ->
      Printf.sprintf
        "Console capture setup failed for '%s' at %s: %s. Check capture file \
         path and permissions."
        instance_name capture_path details
  | Console_session_timed_out { instance_name; timeout_seconds } ->
      Printf.sprintf
        "Console session timed out for '%s' after %.3fs. Increase \
         EPI_CONSOLE_TIMEOUT_SECONDS or retry with interactive console."
        instance_name timeout_seconds
