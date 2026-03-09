type runtime = {
  unit_id : string;
  serial_socket : string;
  disk : string;
  ssh_port : int option;
  ssh_key_path : string;
}

val default_instance_name : string
val state_dir : unit -> string
val instance_dir : string -> string
val instance_path : string -> string -> string
val serial_socket_path : string -> string
val ensure_instance_dir : string -> unit
val save_target : string -> string -> unit
val load_target : string -> string option
val save_runtime : string -> runtime -> unit
val load_runtime : string -> runtime option
val save_mounts : string -> string list -> unit
val load_mounts : string -> string list
val set : instance_name:string -> target:string -> unit
val set_provisioned : instance_name:string -> target:string -> runtime:runtime -> unit
val find : string -> string option
val find_runtime : string -> runtime option
val list : unit -> (string * string) list
val clear_runtime : string -> unit
val remove : string -> unit
val vm_unit_name : instance_name:string -> unit_id:string -> (string, string) result
val slice_name : instance_name:string -> unit_id:string -> (string, string) result
val instance_is_running : string -> bool
val find_running_owner_by_disk : string -> (string * runtime) option
