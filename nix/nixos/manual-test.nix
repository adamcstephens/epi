{
  lib,
  config,
  pkgs,
  ...
}:
{
  options.epi.cloudHypervisor = {
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
  };

  config = {
    epi.cloudHypervisor = {
      kernel = "${config.system.build.kernel}/${config.system.boot.loader.kernelFile}";
      initrd = "${config.system.build.initialRamdisk}/${config.system.boot.loader.initrdFile}";
      disk = "${config.system.build.images.qemu}/nixos-image-qcow2-${config.system.nixos.label}-${pkgs.stdenv.hostPlatform.system}.qcow2";
      cmdline = "console=ttyS0 root=LABEL=nixos ro init=/nix/var/nix/profiles/system/init";
      cpus = 1;
      memory_mib = 1024;
    };

    networking.hostName = "manual-test";

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

    # Prevent cloud-init from overriding NixOS network config via networkd.
    # NixOS handles DHCP natively; cloud-init network config conflicts and
    # prevents DHCPv4 from completing (only IPv6 addresses are assigned).
    environment.etc."cloud/cloud.cfg.d/99-disable-network-config.cfg".text = ''
      network:
        config: disabled
    '';

    services.openssh = {
      enable = true;
      settings.PasswordAuthentication = false;
    };

    users.users.root.initialHashedPassword = lib.mkOverride 150 "";

    system.stateVersion = "24.11";
  };
}
