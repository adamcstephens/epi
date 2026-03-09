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

val attach_console :
  ?read_stdin:bool ->
  ?capture_path:string ->
  ?timeout_seconds:float ->
  instance_name:string ->
  Instance_store.runtime ->
  (unit, console_error) result

val pp_console_error : console_error -> string
