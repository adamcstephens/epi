open Test_helpers

let with_mock_runtime f =
  with_temp_dir "epi-vm-test" (fun dir ->
      let kernel = Filename.concat dir "vmlinuz" in
      let disk = Filename.concat dir "disk.img" in
      let initrd = Filename.concat dir "initrd.img" in
      let mutable_disk_dir = Filename.concat dir "mutable" in
      let mutable_disk = Filename.concat mutable_disk_dir "mutable-disk.img" in
      let resolver = Filename.concat dir "resolver.sh" in
      let cloud_hypervisor = Filename.concat dir "cloud-hypervisor.sh" in
      let launch_log = Filename.concat dir "launch.log" in
      write_file kernel "kernel";
      write_file disk "disk";
      write_file initrd "initrd";
      Unix.mkdir mutable_disk_dir 0o755;
      write_file mutable_disk "mutable-disk";
      write_file resolver
        ("#!/usr/bin/env sh\n\
          if [ \"$EPI_TARGET\" = \".#nixosConfigurations.fail-resolve\" ]; then\n\
         \  echo \"resolver exploded\" >&2\n\
         \  exit 21\n\
          fi\n\
          if [ \"$EPI_TARGET\" = \".#nixosConfigurations.missing-disk\" ]; then\n\
         \  printf '{\"kernel\": \"" ^ kernel
       ^ "\", \"cpus\": 2, \"memory_mib\": 1024}'\n\
         \  exit 0\n\
          fi\n\
          if [ \"$EPI_TARGET\" = \".#nixosConfigurations.mutable-disk\" ]; then\n\
         \  printf '{\"kernel\": \"" ^ kernel ^ "\", \"disk\": \""
       ^ mutable_disk ^ "\", \"initrd\": \"" ^ initrd
       ^ "\", \"cpus\": 2, \"memory_mib\": 1024}'\n\
         \  exit 0\n\
          fi\n\
          if [ \"$EPI_TARGET\" = \".#nixosConfigurations.custom-cmdline\" ]; \
          then\n\
         \  printf '{\"kernel\": \"" ^ kernel ^ "\", \"disk\": \"" ^ disk
       ^ "\", \"initrd\": \"" ^ initrd
       ^ "\", \"cmdline\": \"console=ttyS0 root=/dev/vda1 ro\", \"cpus\": 2, \
          \"memory_mib\": 1024}'\n\
         \  exit 0\n\
          fi\n\
          if [ \"$EPI_TARGET\" = \".#nixosConfigurations.owner\" ] || [ \
          \"$EPI_TARGET\" = \".#nixosConfigurations.qa\" ]; then\n\
         \  printf '{\"kernel\": \"" ^ kernel ^ "\", \"disk\": \"" ^ disk
       ^ "\", \"initrd\": \"" ^ initrd
       ^ "\", \"cpus\": 2, \"memory_mib\": 1024}'\n\
         \  exit 0\n\
          fi\n\
          if [ \"$EPI_TARGET\" = \".#nixosConfigurations.user-configured\" ]; \
          then\n\
         \  printf '{\"kernel\": \"" ^ kernel ^ "\", \"disk\": \"" ^ disk
       ^ "\", \"initrd\": \"" ^ initrd
       ^ "\", \"cpus\": 2, \"memory_mib\": 1024, \"configuredUsers\": \
          [\"root\", \"'\"$USER\"'\"]}'\n\
         \  exit 0\n\
          fi\n\
          SAFE_TARGET=$(echo \"$EPI_TARGET\" | tr '/:' '__')\n\
          TARGET_DISK=\"" ^ dir ^ "/disk-${SAFE_TARGET}.img\"\ncp -n \"" ^ disk
       ^ "\" \"$TARGET_DISK\" 2>/dev/null || true\nprintf '{\"kernel\": \""
       ^ kernel ^ "\", \"disk\": \"'\"$TARGET_DISK\"'\", \"initrd\": \""
       ^ initrd ^ "\", \"cpus\": 2, \"memory_mib\": 1536}'\n");
      write_file cloud_hypervisor
        ("#!/usr/bin/env sh\necho \"$*\" >> \"" ^ launch_log
       ^ "\"\n\
          if [ \"$EPI_FORCE_LAUNCH_FAIL\" = \"1\" ]; then\n\
         \  echo \"mock launch failed\" >&2\n\
         \  exit 12\n\
          fi\n\
          if [ \"$EPI_FORCE_LOCK_FAIL\" = \"1\" ]; then\n\
         \  echo \"disk lock conflict: Resource temporarily unavailable\" >&2\n\
         \  exit 23\n\
          fi\n\
          exec sleep \"${EPI_MOCK_VM_SLEEP:-30}\"\n");
      let xorriso = Filename.concat dir "xorriso.sh" in
      write_file xorriso
        "#!/usr/bin/env sh\n\
         # Mock xorriso: create a fake ISO file at -output path\n\
         OUTPUT=\"\"\n\
         while [ $# -gt 0 ]; do\n\
        \  case \"$1\" in\n\
        \    -output) OUTPUT=\"$2\"; shift 2 ;;\n\
        \    *) shift ;;\n\
        \  esac\n\
         done\n\
         if [ -n \"$OUTPUT\" ]; then\n\
        \  echo \"mock-iso-content\" > \"$OUTPUT\"\n\
         fi\n\
         exit 0\n";
      let passt = Filename.concat dir "passt.sh" in
      write_file passt
        "#!/usr/bin/env sh\n\
         # Mock passt: find --socket arg, touch the socket file, stay alive\n\
         prev=\"\"\n\
         for arg in \"$@\"; do\n\
        \  if [ \"$prev\" = \"--socket\" ]; then\n\
        \    touch \"$arg\"\n\
        \  fi\n\
        \  prev=\"$arg\"\n\
         done\n\
         exec sleep 30\n";
      let mock_systemd_dir = Filename.concat dir "mock-systemd" in
      Unix.mkdir mock_systemd_dir 0o755;
      let systemd_run = Filename.concat dir "systemd-run.sh" in
      write_file systemd_run
        ("#!/usr/bin/env sh\n\
          UNIT=\"\"\n\
          for arg in \"$@\"; do\n\
         \  case \"$arg\" in\n\
         \    --unit=*) UNIT=\"${arg#--unit=}\" ;;\n\
         \  esac\n\
          done\n\
          while [ \"$1\" != \"--\" ] && [ $# -gt 0 ]; do shift; done\n\
          shift\n\
          \"$@\" >/dev/null 2>&1 &\n\
          PID=$!\n\
          if [ -n \"$UNIT\" ]; then\n\
         \  echo \"$PID\" > \"" ^ mock_systemd_dir
       ^ "/$UNIT.pid\"\nfi\nexit 0\n");
      let systemctl = Filename.concat dir "systemctl.sh" in
      write_file systemctl
        ("#!/usr/bin/env sh\nshift\nACTION=\"$1\"\nUNIT=\"$2\"\nMOCK_DIR=\""
       ^ mock_systemd_dir
       ^ "\"\n\
          case \"$ACTION\" in\n\
         \  is-active)\n\
         \    for f in \"$MOCK_DIR\"/*.pid; do\n\
         \      [ -f \"$f\" ] || continue\n\
         \      base=$(basename \"$f\" .pid)\n\
         \      case \"$UNIT\" in\n\
         \        *\"$base\"*)\n\
         \          if kill -0 $(cat \"$f\") 2>/dev/null; then\n\
         \            echo active\n\
         \            exit 0\n\
         \          fi\n\
         \          ;;\n\
         \      esac\n\
         \    done\n\
         \    echo inactive\n\
         \    exit 3\n\
         \    ;;\n\
         \  stop)\n\
         \    for f in \"$MOCK_DIR\"/*.pid; do\n\
         \      [ -f \"$f\" ] || continue\n\
         \      base=$(basename \"$f\" .pid)\n\
         \      case \"$UNIT\" in\n\
         \        *\"$base\"*)\n\
         \          kill $(cat \"$f\") 2>/dev/null\n\
         \          rm -f \"$f\"\n\
         \          ;;\n\
         \      esac\n\
         \    done\n\
         \    exit 0\n\
         \    ;;\n\
          esac\n\
          exit 0\n");
      let virtiofsd = Filename.concat dir "virtiofsd.sh" in
      write_file virtiofsd
        "#!/usr/bin/env sh\n\
         # Mock virtiofsd: find --socket-path arg, touch the socket file, stay \
         alive\n\
         prev=\"\"\n\
         for arg in \"$@\"; do\n\
        \  if [ \"$prev\" = \"--socket-path\" ]; then\n\
        \    touch \"$arg\"\n\
        \  fi\n\
        \  prev=\"$arg\"\n\
         done\n\
         exec sleep 30\n";
      make_executable resolver;
      make_executable cloud_hypervisor;
      make_executable xorriso;
      make_executable passt;
      make_executable systemd_run;
      make_executable systemctl;
      make_executable virtiofsd;
      let cache_dir = Filename.concat dir "cache" in
      Unix.mkdir cache_dir 0o755;
      let extra_env =
        [
          ("EPI_TARGET_RESOLVER_CMD", resolver);
          ("EPI_CLOUD_HYPERVISOR_BIN", cloud_hypervisor);
          ("EPI_XORRISO_BIN", xorriso);
          ("EPI_PASST_BIN", passt);
          ("EPI_VIRTIOFSD_BIN", virtiofsd);
          ("EPI_SYSTEMD_RUN_BIN", systemd_run);
          ("EPI_SYSTEMCTL_BIN", systemctl);
          ("EPI_MOCK_SYSTEMD_DIR", mock_systemd_dir);
          ("EPI_MOCK_VM_SLEEP", "30");
          ("EPI_CACHE_DIR", cache_dir);
          ("EPI_NO_WAIT", "1");
        ]
      in
      (* Set in test process so test_helpers.stop_unit uses mock systemctl *)
      let saved_systemctl = Sys.getenv_opt "EPI_SYSTEMCTL_BIN" in
      Unix.putenv "EPI_SYSTEMCTL_BIN" systemctl;
      Fun.protect
        ~finally:(fun () ->
          match saved_systemctl with
          | Some v -> Unix.putenv "EPI_SYSTEMCTL_BIN" v
          | None -> Unix.putenv "EPI_SYSTEMCTL_BIN" "")
        (fun () -> f ~extra_env ~launch_log ~disk))
