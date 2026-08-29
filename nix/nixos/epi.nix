{
  lib,
  config,
  pkgs,
  modulesPath,
  ...
}:
let
  cfg = config.epi;
  epiInit = pkgs.writeShellApplication {
    name = "epi-init";

    bashOptions = [
      "errexit"
      "pipefail"
    ];

    runtimeInputs = [
      pkgs.coreutils
      pkgs.getent
      pkgs.util-linux
      pkgs.jq
      pkgs.shadow
      pkgs.hostname-debian
    ];

    text = ''
      if [ -f /nix-path-registration ]; then
        ${config.nix.package.out}/bin/nix-store --load-db < /nix-path-registration &&
        rm /nix-path-registration
      fi

      export PATH="/run/wrappers/bin:$PATH"
      EPIDATA=$(blkid -L epidata 2>/dev/null) || exit 0
      [ -b "$EPIDATA" ] || exit 0

      MOUNT_DIR="/run/epi-init/epidata"
      mkdir -p "$MOUNT_DIR"
      mount -o ro "$EPIDATA" "$MOUNT_DIR" || exit 0

      EPI_JSON="$MOUNT_DIR/epi.json"
      [ -f "$EPI_JSON" ] || exit 0

      # Read fields from epi.json
      HOSTNAME=$(jq -r '.hostname' "$EPI_JSON")
      USERNAME=$(jq -r '.user.name' "$EPI_JSON")
      UID_VAL=$(jq -r '.user.uid // empty' "$EPI_JSON")

      # Set hostname (runtime only, filesystem is read-only)
      hostname "$HOSTNAME"

      # Create user if not exists
      if ! id "$USERNAME" &>/dev/null; then
        USERADD_ARGS=(-m -G wheel -s /run/current-system/sw/bin/bash)
        if [ -n "$UID_VAL" ]; then
          USERADD_ARGS+=(-u "$UID_VAL")
        fi
        useradd "''${USERADD_ARGS[@]}" "$USERNAME"
      fi

      # SSH authorized keys
      KEY_COUNT=$(jq -r '.user.ssh_authorized_keys // [] | length' "$EPI_JSON")
      if [ "$KEY_COUNT" -gt 0 ]; then
        mkdir -p /etc/ssh/authorized_keys.d
        jq -r '.user.ssh_authorized_keys[]' "$EPI_JSON" > "/etc/ssh/authorized_keys.d/$USERNAME"
        chmod 644 "/etc/ssh/authorized_keys.d/$USERNAME"
      fi

      # Virtiofs mounts
      USER_HOME=$(getent passwd "$USERNAME" | cut -d: -f6)
      HOST_HOME=$(jq -r '.host_home // empty' "$EPI_JSON")
      MOUNT_COUNT=$(jq -r '.mounts // [] | length' "$EPI_JSON")
      for i in $(seq 0 $((MOUNT_COUNT - 1))); do
        HOST_PATH=$(jq -r ".mounts[$i].host" "$EPI_JSON")
        GUEST_PATH=$(jq -r ".mounts[$i].guest" "$EPI_JSON")
        if [ -n "$USER_HOME" ] && [[ "$GUEST_PATH" == "$USER_HOME"/* ]]; then
          su - "$USERNAME" -c "mkdir -p '$GUEST_PATH'"
        else
          mkdir -p "$GUEST_PATH"
        fi
        mount -t virtiofs "hostfs-$i" "$GUEST_PATH"

        # When the destination wasn't explicitly overridden (guest == host)
        # and the host home differs from the guest home (e.g. macOS
        # /Users/<user> vs /home/<user>), bind the mount into the guest home
        # so it is reachable at the natural path too.
        if [ "$GUEST_PATH" = "$HOST_PATH" ] && [ -n "$HOST_HOME" ] && [ -n "$USER_HOME" ] && [[ "$HOST_PATH" == "$HOST_HOME"/* ]]; then
          BIND_TARGET="$USER_HOME''${HOST_PATH#"$HOST_HOME"}"
          if [ "$BIND_TARGET" != "$HOST_PATH" ]; then
            su - "$USERNAME" -c "mkdir -p '$BIND_TARGET'"
            mount --bind "$HOST_PATH" "$BIND_TARGET"
          fi
        fi
      done
    '';
  };
  epiInitHooks = pkgs.writeShellApplication {
    name = "epi-init-hooks";

    bashOptions = [
      "errexit"
      "pipefail"
    ];

    runtimeInputs = [
      pkgs.coreutils
      pkgs.util-linux
      pkgs.jq
    ];

    text = ''
      export PATH="/run/wrappers/bin:$PATH"

      EPI_JSON="/run/epi-init/epidata/epi.json"
      [ -f "$EPI_JSON" ] || exit 0

      HOOK_GUARD="/var/lib/epi-init-done"
      [ ! -f "$HOOK_GUARD" ] || exit 0

      USERNAME=$(jq -r '.user.name' "$EPI_JSON")

      HOOKS_DIR="/run/epi-init/epidata/hooks"
      if [ -d "$HOOKS_DIR" ]; then
        for hook in "$HOOKS_DIR"/*; do
          [ -f "$hook" ] && [ -x "$hook" ] || continue
          echo "epi-init-hooks: running guest hook $(basename "$hook")"
          su - "$USERNAME" -c "$hook" || echo "epi-init-hooks: hook $(basename "$hook") failed (exit $?)"
        done
      fi

      ${lib.concatStrings (
        lib.mapAttrsToList (name: path: ''
          echo "epi-init-hooks: running nix guest hook ${name}"
          su - "$USERNAME" -c "${path}" || echo "epi-init-hooks: nix guest hook ${name} failed (exit $?)"
        '') cfg.hooks.guest-init
      )}

      touch "$HOOK_GUARD"

      umount /run/epi-init/epidata 2>/dev/null || true
      rmdir /run/epi-init/epidata 2>/dev/null || true
    '';
  };

  # Report the guest's DHCP-assigned IPv4 to the host through the
  # epi-internal `epistate` virtio-fs share (macOS VZ backend, epi-26/44).
  # The share only exists under VZ; on cloud-hypervisor the tag is absent
  # and this exits quietly. Overwrites on every boot so the host never
  # reads a stale address.
  epiReportIp = pkgs.writeShellApplication {
    name = "epi-report-ip";

    bashOptions = [
      "errexit"
      "pipefail"
    ];

    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.iproute2
      pkgs.util-linux
    ];

    text = ''
      # The epistate share only exists under the macOS VZ backend; on
      # cloud-hypervisor the mount fails and we exit quietly.
      mkdir -p /run/epi-state
      if ! mountpoint -q /run/epi-state; then
        if ! mount -t virtiofs epistate /run/epi-state 2>/dev/null; then
          echo "epi-report-ip: no epistate share, skipping"
          exit 0
        fi
      fi

      for _ in $(seq 1 30); do
        addr=$(ip -4 -o addr show scope global | awk '{ print $4 }' | cut -d/ -f1 | head -1)
        if [ -n "$addr" ]; then
          printf '%s\n' "$addr" > /run/epi-state/ip
          echo "epi-report-ip: reported $addr"
          exit 0
        fi
        sleep 1
      done

      echo "epi-report-ip: no global IPv4 address found" >&2
      exit 1
    '';
  };

  epiSshEntry = pkgs.writeShellApplication {
    name = "epi-ssh-entry";

    bashOptions = [ ];

    runtimeInputs = [ ];

    text = ''
      PROJECT_DIR="''${1:-}"

      if [ -z "$PROJECT_DIR" ]; then
        exec "$SHELL" -l
      fi

      if [ ! -d "$PROJECT_DIR" ]; then
        echo "warning: project directory $PROJECT_DIR does not exist in guest" >&2
        exec "$SHELL" -l
      fi

      cd "$PROJECT_DIR" || exit
      exec "$SHELL" -l
    '';
  };

  imageStorePaths = [ config.system.build.toplevel ] ++ cfg.extraStorePaths;

  closureInfo = pkgs.closureInfo {
    rootPaths = imageStorePaths;
  };
in
{
  disabledModules = [ "virtualisation/disk-image.nix" ];
  imports = [ "${modulesPath}/image/repart.nix" ];

  options.epi = {
    enable = lib.mkEnableOption "epi";

    extraStorePaths = lib.mkOption {
      type = lib.types.listOf lib.types.pathInStore;
      description = ''
        extra store paths to copy into the disk image.
        for example: `[ config.home-manager.users.adam.home.activationPackage ]`
      '';
      default = [ ];
    };

    kernel = lib.mkOption {
      type = lib.types.str;
      description = "Kernel image path used by epi up cloud-hypervisor launch.";
    };

    disk = lib.mkOption {
      type = lib.types.str;
      description = "Raw disk image path used by the epi vz backend.";
    };

    diskQcow2 = lib.mkOption {
      type = lib.types.str;
      description = "qcow2 disk image path used by the epi cloud-hypervisor backend.";
    };

    initrd = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional initrd path used by epi up cloud-hypervisor launch.";
    };

    cmdline = lib.mkOption {
      type = lib.types.str;
      default = "console=ttyS0 root=/dev/vda2 ro";
      description = "Kernel command line used by epi up cloud-hypervisor launch.";
    };

    configuredUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = "Usernames configured in the NixOS config, auto-detected from users.users.";
    };

    hooks = {
      guest-init = lib.mkOption {
        type = lib.types.attrsOf lib.types.path;
        default = { };
        description = "Guest-init hook scripts declared in NixOS config. Keys are script names (used for lexical ordering), values are paths to executable scripts.";
      };

      post-launch = lib.mkOption {
        type = lib.types.attrsOf lib.types.path;
        default = { };
        description = "Post-launch hook scripts declared in NixOS config. Keys are script names (used for lexical ordering), values are paths to executable scripts.";
      };

      pre-stop = lib.mkOption {
        type = lib.types.attrsOf lib.types.path;
        default = { };
        description = "Pre-stop hook scripts declared in NixOS config. Keys are script names (used for lexical ordering), values are paths to executable scripts.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    epi = {
      kernel = "${config.system.build.kernel}/${config.system.boot.loader.kernelFile}";
      initrd = "${config.system.build.initialRamdisk}/${config.system.boot.loader.initrdFile}";
      disk = "${config.system.build.image}/${config.image.baseName}.raw";
      diskQcow2 = "${config.system.build.epiDiskQcow2}/${config.image.baseName}.qcow2";
      # Derived from boot.kernelParams rather than hardcoded: the systemd
      # initrd needs NixOS' own `root=fstab` sentinel, which tells
      # systemd-fstab-generator to take the root mount from the initrd fstab
      # instead of synthesizing a second, conflicting sysroot.mount.
      cmdline = "console=hvc0 ${toString config.boot.kernelParams} init=${config.system.build.toplevel}/init";
      configuredUsers =
        let
          normalUsers = lib.filterAttrs (_: user: user.isNormalUser) config.users.users;
        in
        builtins.attrNames normalUsers;
    };

    system.extraDependencies = [
      # Fails the build if a kernel symbol the guest depends on did not
      # survive Kconfig dependency resolution.
      config.boot.kernelPackages.epiConfigCheck
    ]
    ++ (lib.attrValues cfg.hooks.post-launch)
    ++ (lib.attrValues cfg.hooks.pre-stop);

    # qcow2 stores only allocated clusters, so unlike the fixed-size sparse
    # raw it stays small through NAR serialization (nix copy, binary caches).
    system.build.epiDiskQcow2 =
      pkgs.runCommand "epi-disk-qcow2"
        {
          nativeBuildInputs = [ pkgs.qemu-utils ];
        }
        ''
          mkdir -p $out
          qemu-img convert -f raw -O qcow2 -c -o compression_type=zstd \
            ${config.system.build.image}/${config.image.baseName}.raw \
            $out/${config.image.baseName}.qcow2
        '';

    environment.systemPackages = [
      pkgs.jq
      pkgs.rsync
      epiSshEntry
    ];

    fileSystems."/" = {
      device = "/dev/disk/by-label/nixos";
      fsType = "ext4";
      autoResize = true;
    };

    boot.kernelPackages = import ./kernel.nix { inherit lib pkgs; };

    boot.loader.grub.enable = false;
    boot.growPartition = true;

    # Every driver the guest needs is built into the kernel, so the initrd
    # carries no modules and stage-1 has nothing to probe.
    boot.initrd.includeDefaultModules = false;
    boot.initrd.kernelModules = [ ];
    boot.initrd.availableKernelModules = lib.mkForce [ ];
    boot.initrd.systemd.enable = true;

    # console=ttyS0 is deliberately absent: printk on a synchronous
    # 115200-baud serial port blocks on every message. hvc0 carries the
    # console, and cloud-hypervisor captures it to console.log.
    boot.kernelParams = [ "quiet" ];

    # NixOS loads "loop" and "atkbd" by default; neither exists in this
    # kernel, and systemd-modules-load logs an error for each one.
    boot.kernelModules = lib.mkForce [ ];
    boot.consoleLogLevel = 3;

    # Use systemd-networkd instead of dhcpcd — faster DHCP
    networking.useDHCP = true;
    networking.useNetworkd = true;

    # Disable firewall — VM runs behind passt (user-mode networking)
    networking.firewall.enable = false;

    # Recover the guest clock quickly after host sleep. timesyncd is
    # SNTP-only with poll backoff up to ~34 min and no host-clock source,
    # so the clock stays wrong for a long time after wake. chrony steps
    # any large offset immediately (makestep) and, under KVM/cloud-
    # hypervisor, syncs straight off the host clock via the ptp_kvm PHC
    # with no network needed.
    #
    # The host clock is authoritative: when the PHC exists it is the ONLY
    # source. Mixing it with pool servers lets the selection algorithm
    # outvote the PHC as a falseticker whenever the host disagrees with
    # the pool by more than the pool's error bars, and after a long host
    # sleep the PHC's accumulated dispersion exceeds maxdistance right
    # when it is needed — leaving no selectable source, so makestep never
    # fires. Pool servers are only used when the PHC is absent (VZ, where
    # chronyd would treat the missing refclock device as a fatal error).
    services.timesyncd.enable = false;
    services.chrony = {
      enable = true;
      servers = [ ];
      # makestep.limit can't express -1 (unlimited); use extraConfig
      makestep.enable = false;
      extraConfig = ''
        makestep 1.0 -1
        confdir /run/chrony.d
      '';
    };
    systemd.services.chronyd = {
      serviceConfig.RuntimeDirectory = "chrony.d";
      preStart = ''
        if [ -e /dev/ptp_kvm ]; then
          echo 'refclock PHC /dev/ptp_kvm poll 0 dpoll -2' > /run/chrony.d/epi.conf
        else
          cat > /run/chrony.d/epi.conf <<EOF
        ${lib.concatMapStringsSep "\n" (s: "pool ${s} iburst") config.networking.timeServers}
        EOF
        fi
      '';
    };

    nix.settings = {
      experimental-features = "nix-command flakes";
      trusted-users = [
        "root"
        "@wheel"
      ];
    };

    # Disable unnecessary services for a lightweight VM
    systemd.services."getty@".enable = false;

    # Cap how long the per-user systemd manager waits for its own services
    # to stop before SIGKILL. Without this, a single user service that
    # ignores SIGTERM blocks `multi-user.target` shutdown for the full
    # DefaultTimeoutStopSec (90s), which makes `epi stop` painfully slow.
    systemd.user.settings.Manager.DefaultTimeoutStopSec = "5s";

    systemd.services.epi-init = {
      description = "epi guest initialization";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe epiInit;
        RuntimeDirectory = "epi-init";
      };
      after = [ "local-fs.target" ];
      before = [
        "multi-user.target"
        "sshd.service"
      ];
      wantedBy = [ "multi-user.target" ];
    };

    systemd.services.epi-report-ip = {
      description = "epi report guest IP to host";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe epiReportIp;
      };
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
    };

    systemd.services.epi-init-hooks = {
      description = "epi guest initialization hooks";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe epiInitHooks;
      };
      after = [
        "epi-init.service"
        "network-online.target"
      ];
      wants = [ "network-online.target" ];
      before = [ "multi-user.target" ];
      wantedBy = [ "multi-user.target" ];
    };

    security.sudo.wheelNeedsPassword = false;

    services.logrotate.enable = false;

    services.openssh = {
      enable = true;
      settings.PasswordAuthentication = false;
    };

    users.users.root.initialHashedPassword = lib.mkOverride 150 "";

    image.repart = {
      name = "epi-disk";
      sectorSize = 512;
      partitions."10-root" = {
        repartConfig = {
          Type = "root";
          Format = "ext4";
          Label = "nixos";
          # Fixed size instead of Minimize=guess: guess populates the
          # filesystem twice to find the minimal size. The raw stays sparse
          # on disk, and backends grow the disk to the instance size at
          # launch, so the image itself needs no free-space headroom.
          SizeMinBytes = "20G";
          SizeMaxBytes = "20G";
        };
        storePaths = imageStorePaths;
        contents = {
          "/nix-path-registration".source = "${closureInfo}/registration";
        };
      };
    };
  };
}
