let default_descriptor : Epi.Target.descriptor =
  {
    kernel = "/tmp/mock-kernel";
    disk = "/tmp/mock-disk.img";
    initrd = Some "/tmp/mock-initrd.img";
    cmdline = Epi.Target.default_cmdline;
    cpus = 2;
    memory_mib = 1024;
    configured_users = [];
    hooks = { post_launch = []; pre_stop = [] };
  }

let default_runtime : Epi.Instance_store.runtime =
  {
    unit_id = "mock-unit-id";
    serial_socket = "/tmp/mock-serial.sock";
    disk = "/tmp/mock-disk.img";
    ssh_port = Some 2222;
    ssh_key_path = "/tmp/mock-key";
  }

let make_mock_resolver
    ?(resolve = fun _target -> Ok default_descriptor)
    ?(resolve_cached = None)
    () : (module Epi.Target.Resolver) =
  let resolve_fn = resolve in
  let resolve_cached_fn = match resolve_cached with
    | Some f -> f
    | None -> fun ~rebuild:_ target ->
        match resolve_fn target with
        | Ok d -> Ok (Epi.Target.Resolved d)
        | Error e -> Error e
  in
  (module struct
    let resolve_descriptor = resolve_fn
    let resolve_descriptor_cached = resolve_cached_fn
  end : Epi.Target.Resolver)

let make_mock_runner
    ?(launch = fun ~mount_paths:_ ~disk_size:_ ~instance_name:_ ~target:_ _descriptor -> Ok default_runtime)
    ?(wait_ssh = fun ~ssh_port:_ ~ssh_key_path:_ ~timeout_seconds:_ -> Ok ())
    () : (module Epi.Vm_launch.Runner) =
  let launch_fn = launch in
  let wait_ssh_fn = wait_ssh in
  (module struct
    let launch_vm = launch_fn
    let wait_for_ssh = wait_ssh_fn
  end : Epi.Vm_launch.Runner)

let call_counter () =
  let count = ref 0 in
  let increment () = incr count in
  let get () = !count in
  (increment, get)
