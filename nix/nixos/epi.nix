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
      MOUNT_COUNT=$(jq -r '.mounts // [] | length' "$EPI_JSON")
      for i in $(seq 0 $((MOUNT_COUNT - 1))); do
        MOUNT_PATH=$(jq -r ".mounts[$i]" "$EPI_JSON")
        mkdir -p "$MOUNT_PATH"
        mount -t virtiofs "hostfs-$i" "$MOUNT_PATH"
        chown "$USERNAME:" "$MOUNT_PATH"
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
      cmdline = "console=ttyS0 root=LABEL=nixos rw init=${config.system.build.toplevel}/init";
      cpus = 1;
      memory_mib = 1024;
      configuredUsers = builtins.attrNames config.users.users;
    };

    system.extraDependencies =
      (lib.attrValues cfg.hooks.post-launch) ++ (lib.attrValues cfg.hooks.pre-stop);

    environment.systemPackages = [ pkgs.jq pkgs.rsync ];

    fileSystems."/" = {
      device = "/dev/disk/by-label/nixos";
      fsType = "ext4";
      autoResize = true;
    };

    boot.loader.grub.enable = false;
    boot.growPartition = true;

    boot.initrd.availableKernelModules = [
      "virtio_pci"
      "virtio_blk"
      "virtio_net"
      "virtiofs"
      "ext4"
    ];

    networking.useDHCP = true;

    nix.settings = {
      extra-experimental-features = "nix-command flakes";
    };

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
          Minimize = "guess";
        };
        storePaths = imageStorePaths;
        contents = {
          "/nix-path-registration".source = "${closureInfo}/registration";
        };
      };
    };
  };
}
