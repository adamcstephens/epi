{
  lib,
  config,
  pkgs,
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

      chown -R "$USERNAME:" "~$USERNAME"
    '';
  };
in
{
  options.epi = {
    enable = lib.mkEnableOption "epi";

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
  };

  config = lib.mkIf cfg.enable {
    epi = {
      kernel = "${config.system.build.kernel}/${config.system.boot.loader.kernelFile}";
      initrd = "${config.system.build.initialRamdisk}/${config.system.boot.loader.initrdFile}";
      disk = "${config.system.build.images.qemu}/nixos-image-qcow2-${config.system.nixos.label}-${pkgs.stdenv.hostPlatform.system}.qcow2";
      cmdline = "console=ttyS0 root=LABEL=nixos ro init=/nix/var/nix/profiles/system/init";
      cpus = 1;
      memory_mib = 1024;
      configuredUsers = builtins.attrNames config.users.users;
    };

    environment.systemPackages = [ pkgs.jq ];

    fileSystems."/" = {
      device = "/dev/disk/by-label/nixos";
      fsType = "ext4";
      autoResize = true;
    };

    boot.growPartition = true;

    boot.loader.grub.device = "/dev/vda";

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
  };
}
