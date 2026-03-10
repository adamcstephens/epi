type t

val of_string : string -> (t, [ `Msg of string ]) result
val to_string : t -> string

type descriptor = {
  kernel : string;
  disk : string;
  initrd : string option;
  cmdline : string;
  cpus : int;
  memory_mib : int;
  configured_users : string list;
}

type resolution_error = {
  target : string;
  details : string;
  exit_code : int option;
}

type cache_result = Cached of descriptor | Resolved of descriptor

val default_cmdline : string
val descriptor_of_json : Yojson.Basic.t -> descriptor
val descriptor_to_json : descriptor -> Yojson.Basic.t
val resolve_descriptor : string -> (descriptor, resolution_error) result
val resolve_descriptor_cached : rebuild:bool -> string -> (cache_result, resolution_error) result
val validate_descriptor : target:string -> descriptor -> (unit, string) result
val is_nix_store_path : string -> bool
val descriptor_paths : descriptor -> string list
val split_target : string -> (string * string) option
val store_root_of_path : string -> string option
val descriptor_paths_exist : descriptor -> bool
val cache_dir : unit -> string
val validate_descriptor_coherence : descriptor -> (unit, string) result
