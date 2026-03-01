{ lib, config, ... }:
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
      # Local writable image used for manual `epi up` testing.
      disk = "/home/adam/projects/epi/nixos.img";
      cpus = 1;
      memory_mib = 1024;
    };

    networking.hostName = "manual-test";

    system.stateVersion = "24.11";
  };
}
