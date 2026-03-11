{
  lib,
  config,
  pkgs,
  modulesPath,
  ...
}:
let
  cfg = config.epi;
  overlayEnabled = cfg.overlayStore.enable;
  emptyFile = builtins.toFile "keep" "";
  epiInit = pkgs.writeShellApplication {
    name = "epi-init";

    bashOptions = [
      "errexit"
      "pipefail"
    ];

    runtimeInputs = [
      pkgs.coreutils
      pkgs.util-linux
      pkgs.jq
      pkgs.shadow
      pkgs.hostname-debian
    ];

    text = ''
      EPIDATA=$(blkid -L epidata 2>/dev/null) || exit 0
      [ -b "$EPIDATA" ] || exit 0

      TMPDIR=$(mktemp -d)
      trap 'umount "$TMPDIR" 2>/dev/null || true; rmdir "$TMPDIR" 2>/dev/null || true' EXIT

      mount -o ro "$EPIDATA" "$TMPDIR" || exit 0

      EPI_JSON="$TMPDIR/epi.json"
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
      MOUNT_COUNT=$(jq -r '.mounts // [] | length' "$EPI_JSON")
      for i in $(seq 0 $((MOUNT_COUNT - 1))); do
        MOUNT_PATH=$(jq -r ".mounts[$i]" "$EPI_JSON")
        mkdir -p "$MOUNT_PATH"
        mount -t virtiofs "hostfs-$i" "$MOUNT_PATH"
        chown "$USERNAME:" "$MOUNT_PATH"
      done

      HOME_DIR=$(eval echo "~$USERNAME")
      chown -R "$USERNAME:" "$HOME_DIR"

      # Guest hooks: run on first boot only
      HOOK_GUARD="/var/lib/epi-init-done"
      if [ ! -f "$HOOK_GUARD" ]; then
        HOOKS_DIR="$TMPDIR/hooks"
        if [ -d "$HOOKS_DIR" ]; then
          for hook in "$HOOKS_DIR"/*; do
            [ -f "$hook" ] && [ -x "$hook" ] || continue
            echo "epi-init: running guest hook $(basename "$hook")"
            su - "$USERNAME" -c "$hook" || echo "epi-init: hook $(basename "$hook") failed (exit $?)"
          done
        fi
        touch "$HOOK_GUARD"
      fi
    '';
  };
in
{
  disabledModules = [ "virtualisation/disk-image.nix" ];
  imports = [ "${modulesPath}/image/repart.nix" ];

  options.epi = {
    enable = lib.mkEnableOption "epi";

    overlayStore = {
      enable = lib.mkEnableOption "overlay store (host /nix shared via virtiofs)";
    };

    kernel = lib.mkOption {
      type = lib.types.str;
      description = "Kernel image path used by epi up cloud-hypervisor launch.";
    };

    disk = lib.mkOption {
      type = lib.types.str;
      description = "Disk image path used by epi up cloud-hypervisor launch.";
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

    cpus = lib.mkOption {
      type = lib.types.int;
      default = 1;
      description = "vCPU count used by epi up cloud-hypervisor launch.";
    };

    memory_mib = lib.mkOption {
      type = lib.types.int;
      default = 1024;
      description = "Memory in MiB used by epi up cloud-hypervisor launch.";
    };

    configuredUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = "Usernames configured in the NixOS config, auto-detected from users.users.";


    overlayStoreEnabled = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      description = "Whether overlay store is enabled. Exported in the descriptor JSON.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      # Common config (always applied)
      {
        epi = {
          kernel = "${config.system.build.kernel}/${config.system.boot.loader.kernelFile}";
          initrd = "${config.system.build.initialRamdisk}/${config.system.boot.loader.initrdFile}";
          disk = "${config.system.build.image}/${config.image.baseName}.raw";
          cmdline = "console=ttyS0 root=LABEL=nixos rw init=${config.system.build.toplevel}/init";
          cpus = 1;
          memory_mib = 1024;
          configuredUsers = builtins.attrNames config.users.users;
          overlayStoreEnabled = overlayEnabled;
        };

        environment.systemPackages = [ pkgs.jq ];

        fileSystems."/" = {
          device = "/dev/disk/by-label/nixos";
          fsType = "ext4";
          autoResize = true;
        };

        boot.loader.grub.enable = false;

        boot.initrd.availableKernelModules = [
          "virtio_pci"
          "virtio_blk"
          "virtio_net"
          "virtiofs"
          "ext4"
        ];

        networking.useDHCP = true;

        nix.settings = {
          extra-experimental-features =
            if overlayEnabled then
              "nix-command flakes local-overlay-store read-only-local-store"
            else
              "nix-command flakes";
        };

        systemd.services.epi-init = {
          description = "epi guest initialization";
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = lib.getExe epiInit;
          };
          after = [ "local-fs.target" ];
          before = [
            "multi-user.target"
            "sshd.service"
          ];
          wantedBy = [ "multi-user.target" ];
        };

        security.sudo.wheelNeedsPassword = false;

        services.openssh = {
          enable = true;
          settings.PasswordAuthentication = false;
        };

        users.users.root.initialHashedPassword = lib.mkOverride 150 "";

        system.stateVersion = "24.11";

        image.repart = {
          name = "epi-disk";
          sectorSize = 512;
          partitions."10-root".repartConfig = {
            Type = "root";
            Format = "ext4";
            Label = "nixos";
          };
        };
      }

      # Traditional (non-overlay) config: full store closure in image
      (lib.mkIf (!overlayEnabled) {
        image.repart.partitions."10-root" = {
          storePaths = [ config.system.build.toplevel ];
          repartConfig.Minimize = "guess";
        };
      })

      # Overlay store config: minimal image, host /nix via virtiofs
      #
      # Strategy: virtiofsd on the host shares /nix.  The initrd mounts it
      # at $targetRoot/nix so the init path is immediately accessible.
      # After switch-root a systemd service moves the virtiofs mount to
      # /mnt/host/nix and sets up an overlayfs on /nix/store (the new
      # mount API used in the initrd rejects FUSE as an overlayfs lower
      # layer, but the old mount(2) syscall used at runtime works fine).
      (lib.mkIf overlayEnabled {
        boot.initrd.postMountCommands = ''
          mount -t virtiofs nix-store $targetRoot/nix
        '';

        boot.kernelPackages = pkgs.linuxPackages_latest;


        # Daemon-only nix config: the store setting must be in nix.conf
        # (not NIX_USER_CONF_FILES, which loads too late). But putting it
        # in the main nix.conf makes clients bypass the daemon. Solution:
        # give the daemon its own config dir via NIX_CONF_DIR that includes
        # the standard nix.conf plus the store setting.
        environment.etc."nix/daemon-conf/nix.conf" = {
          source = pkgs.runCommand "nix-daemon-conf" { } ''
            cat ${config.environment.etc."nix/nix.conf".source} > $out
            echo 'store = local-overlay://?root=/&lower-store=local?root=/mnt/host%26read-only=true&upper-layer=/var/nix-overlay/upper&check-mount=false' >> $out
          '';
        };
        systemd.services.nix-daemon.environment.NIX_CONF_DIR = "/etc/nix/daemon-conf";

        environment.systemPackages = [ pkgs.fuse-overlayfs ];

        # fuse.conf: allow non-root users to see FUSE mounts created by root
        environment.etc."fuse.conf".text = "user_allow_other\n";

        systemd.services.nix-store-overlay = {
          description = "fuse-overlayfs mount for /nix/store";
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = pkgs.writeShellScript "nix-store-overlay" ''
              set -euo pipefail
              MOUNT=${pkgs.util-linux}/bin/mount
              MKDIR=${pkgs.coreutils}/bin/mkdir

              # Bind-mount virtiofs to /mnt/host/nix for lower-store access
              $MOUNT --bind /nix /mnt/host/nix
              $MOUNT --make-private /mnt/host/nix
              # fuse-overlayfs at a temp path to avoid FUSE self-referential
              # deadlock (daemon binary lives on the filesystem it serves)
              $MKDIR -p /tmp/nix-overlay
              ${pkgs.fuse-overlayfs}/bin/fuse-overlayfs \
                -o allow_other,lowerdir=/mnt/host/nix/store,upperdir=/var/nix-overlay/upper,workdir=/var/nix-overlay/work \
                /tmp/nix-overlay
              # Bind the overlay onto /nix/store
              $MOUNT --bind /tmp/nix-overlay /nix/store
              # Writable nix state on ext4 (virtiofs /nix/var is read-only)
              # Covers db, daemon-socket, gcroots, profiles, etc.
              $MKDIR -p /var/nix-state/{db,daemon-socket,gc-socket,gcroots/{auto,per-user},profiles/per-user,temproots,userpool,b}
              $MOUNT --bind /var/nix-state /nix/var/nix
            '';
          };
          unitConfig.DefaultDependencies = false;
          after = [ "local-fs.target" ];
          before = [
            "nix-daemon.service"
            "nix-daemon.socket"
            "sysinit.target"
          ];
          wantedBy = [ "sysinit.target" ];
        };

        image.repart.partitions."10-root".contents = {
          "/nix/store/.keep".source = emptyFile;
          "/var/nix-overlay/upper/.keep".source = emptyFile;
          "/var/nix-overlay/work/.keep".source = emptyFile;
          "/var/nix-state/.keep".source = emptyFile;
          "/mnt/host/nix/.keep".source = emptyFile;
        };
      })
    ]
  );
}
