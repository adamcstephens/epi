type output = { status : int; stdout : string; stderr : string }

val run : ?env:string array -> prog:string -> args:string list -> unit -> output
val env_with : (string * string) list -> string array
val escape_unit_name : string -> (string, string) result
val generate_unit_id : unit -> string
val systemctl_bin : string
val run_helper : unit_name:string -> slice:string -> prog:string -> args:string list -> unit -> output
val run_service : unit_name:string -> slice:string -> exec_stop_posts:string list -> prog:string -> args:string list -> unit -> output
val unit_is_active : string -> bool
val stop_unit : string -> bool
