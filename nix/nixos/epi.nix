{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.epi;
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
    };

    boot.loader.grub.device = "/dev/vda";

    boot.initrd.availableKernelModules = [
      "virtio_pci"
      "virtio_blk"
      "virtio_net"
      "ext4"
    ];

    networking.useDHCP = true;

    services.cloud-init.enable = true;

    services.openssh = {
      enable = true;
      settings.PasswordAuthentication = false;
    };

    users.users.root.initialHashedPassword = lib.mkOverride 150 "";

    system.stateVersion = "24.11";
  };
}
