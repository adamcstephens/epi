{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.epi;
  mountGenerator = pkgs.writeShellApplication {
    name = "epi-mounts-generator";

    bashOptions = [
      "errexit"
      "pipefail"
    ];

    runtimeInputs = [
      pkgs.coreutils
      pkgs.util-linux
    ];

    text = ''
      OUTPUT_DIR="/run/systemd/system"
      CIDATA=$(blkid -L cidata 2>/dev/null) || exit 0

      [ -b "$CIDATA" ] || exit 0

      TMPDIR=$(mktemp -d)
      trap 'umount "$TMPDIR" 2>/dev/null || true; rmdir "$TMPDIR" 2>/dev/null || true' EXIT

      mount -o ro "$CIDATA" "$TMPDIR" || exit 0

      EPI_MOUNTS="$TMPDIR/epi-mounts"
      [ -f "$EPI_MOUNTS" ] || exit 0

      mkdir -p "$OUTPUT_DIR/multi-user.target.wants"

      i=0
      while IFS= read -r path || [ -n "$path" ]; do
        [ -n "$path" ] || continue
        unit_name="''${path#/}"
        unit_name="''${unit_name//\//-}.mount"
        cat > "$OUTPUT_DIR/$unit_name" <<UNIT
      [Unit]
      Description=Mount virtiofs host filesystem $path

      [Mount]
      What=hostfs-$i
      Where=$path
      Type=virtiofs
      UNIT
        ln -sf "../$unit_name" "$OUTPUT_DIR/multi-user.target.wants/$unit_name"
        i=$((i + 1))
      done < "$EPI_MOUNTS"
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

    networking.hostName = lib.mkForce "";

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

    systemd.generators.epi-mounts = lib.getExe mountGenerator;

    services.cloud-init.enable = true;

    services.openssh = {
      enable = true;
      settings.PasswordAuthentication = false;
    };

    users.users.root.initialHashedPassword = lib.mkOverride 150 "";

    system.stateVersion = "24.11";
  };
}
