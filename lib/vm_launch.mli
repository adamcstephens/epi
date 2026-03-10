type provision_error =
  | Target_resolution_failed of {
      target : string;
      details : string;
      exit_code : int option;
    }
  | Descriptor_validation_failed of { target : string; details : string }
  | Vm_launch_failed of { target : string; exit_code : int; details : string }
  | Vm_disk_lock_held_by_instance of {
      target : string;
      disk : string;
      owner_instance : string;
      owner_unit_id : string;
    }
  | Vm_exited_immediately of { target : string; details : string }
  | Vm_disk_overlay_prepare_failed of { target : string; details : string }
  | Seed_iso_generation_failed of { target : string; details : string }
  | Passt_missing of { target : string }
  | Passt_failed of { target : string; details : string }
  | Virtiofsd_missing of { target : string }
  | Virtiofsd_failed of { target : string; details : string }
  | Mount_path_not_a_directory of { target : string; path : string }
  | Vm_disk_resize_failed of { target : string; details : string }
  | Systemd_session_unavailable of { target : string; details : string }
  | Ssh_wait_timeout of { timeout_seconds : int }

val generate_epi_json :
  instance_name:string ->
  username:string ->
  ssh_keys:string list ->
  user_exists:bool ->
  host_uid:int ->
  mount_paths:string list ->
  string

val read_ssh_public_keys : unit -> string list
val alloc_free_port : unit -> int

val ensure_writable_disk :
  instance_name:string ->
  target:string ->
  disk_size:string ->
  Target.descriptor ->
  (string, provision_error) result

val generate_ssh_key :
  target:string ->
  instance_name:string ->
  (string * string, provision_error) result

val provision :
  rebuild:bool ->
  mount_paths:string list ->
  disk_size:string ->
  instance_name:string ->
  target:string ->
  (Instance_store.runtime, provision_error) result

val wait_for_ssh :
  ssh_port:int ->
  ssh_key_path:string ->
  timeout_seconds:int ->
  (unit, provision_error) result

val pp_provision_error : provision_error -> string
