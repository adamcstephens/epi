{ lib, pkgs }:
let
  on = lib.mkForce lib.kernel.yes;
  module = lib.mkForce lib.kernel.module;
  off = lib.mkForce lib.kernel.no;

  # Symbols the guest cannot boot or run without. Kconfig `select` can quietly
  # override a request here (nixpkgs' THERMAL_GOV_* pull THERMAL back on, for
  # instance), and ignoreConfigErrors below downgrades that to a warning, so
  # these are asserted against the generated config instead.
  required = {
    y = [
      "VIRTIO_PCI"
      "VIRTIO_BLK"
      "VIRTIO_NET"
      "VIRTIO_CONSOLE"
      "VIRTIO_BALLOON"
      "VIRTIO_FS"
      "FUSE_FS"
      "EXT4_FS"
      "OVERLAY_FS"
      "EROFS_FS"
      "ISO9660_FS"
      "JOLIET"
      "NLS_UTF8"
      "AUTOFS_FS"
      "TMPFS"
      "KVM"
      "PTP_1588_CLOCK_KVM"
      "CGROUPS"
      "NAMESPACES"
      "SECCOMP"
      "BPF_SYSCALL"
    ];
    m = [
      "TUN"
    ];
    n = [
      "DRM"
      "SOUND"
      "USB_SUPPORT"
      "SCSI"
      "ATA"
      "NFS_FS"
      "NETFILTER"
      "ZRAM"
      "F2FS_FS"
      "WLAN"
      "BONDING"
      "BLK_DEV_NVME"
    ];
  };

  kernelPackages = pkgs.linuxPackagesFor (
    pkgs.linuxPackages.kernel.override {
      # nixpkgs' default builds every unspecified driver as a module; with it off
      # the guest kernel ships only what is named here.
      autoModules = false;
      preferBuiltin = true;
      # Disabling a subsystem strands the sub-options nixpkgs' common-config
      # declares for it (turning SND off orphans 29 mandatory SND_* entries),
      # and those are not ours to annotate. The `required` assertion above
      # covers what we actually depend on.
      ignoreConfigErrors = true;

      structuredExtraConfig = {
        VIRTIO = on;
        VIRTIO_PCI = on;
        VIRTIO_MMIO = on;
        VIRTIO_BLK = on;
        VIRTIO_NET = on;
        VIRTIO_CONSOLE = on;
        VIRTIO_BALLOON = on;
        VIRTIO_INPUT = off;
        VIRTIO_FS = on;
        FUSE_FS = on;

        EXT4_FS = on;
        OVERLAY_FS = on;
        EROFS_FS = on;
        SQUASHFS = on;
        # systemd mounts its .automount units through autofs.
        AUTOFS_FS = on;
        # epi-init mounts the epidata seed ISO; Joliet needs the NLS tables.
        ISO9660_FS = on;
        JOLIET = on;
        NLS = on;
        NLS_DEFAULT = lib.mkForce (lib.kernel.freeform "utf8");
        NLS_UTF8 = on;
        NLS_CODEPAGE_437 = on;
        NLS_ISO8859_1 = on;

        # Nothing outside epi's supported surface is built. The guest is a
        # fixed virtual machine: it has no physical hardware, no firewall
        # (networking.firewall.enable = false), and boots by direct kernel
        # handoff rather than EFI.
        DRM = off;
        FB = off;
        SOUND = off;
        WLAN = off;
        USB_SUPPORT = off;
        SCSI = off;
        ATA = off;
        MD = off;
        BLK_DEV_DM = off;
        BLK_DEV_NVME = off;
        NVME_CORE = off;
        NVME_TARGET = off;
        INFINIBAND = off;
        HYPERV = off;
        XEN = off;

        # Laptop, vendor and firmware platform drivers: Dell/HP/ChromeOS/Apple.
        X86_PLATFORM_DEVICES = off;
        CHROME_PLATFORMS = off;
        MFD_CROS_EC_DEV = off;
        FIRMWARE_ATTRIBUTES_CLASS = off;
        PLATFORM_PROFILE = off;
        DCDBAS = off;
        DELL_RBU = off;
        ACPI_WMI = off;

        # Confidential computing and EFI: neither backend uses them, and the
        # guest is direct-kernel-booted so there are no EFI variables.
        AMD_MEM_ENCRYPT = off;
        SEV_GUEST = off;
        INTEL_TDX_GUEST = off;
        TSM_REPORTS = off;
        EFI = off;
        EFI_VARS_PSTORE = off;

        # Power, thermal and crypto-accelerator drivers for real silicon.
        INTEL_RAPL = off;
        INTEL_RAPL_CORE = off;
        X86_PKG_TEMP_THERMAL = off;
        CRYPTO_DEV_CCP = off;
        ACPI_DPTF = off;
        DPTF_POWER = off;
        DPTF_PCH_FIVR = off;

        # Filesystems epi never mounts. The root is ext4, the seed is iso9660,
        # the store overlay is overlayfs/erofs; nothing else is reachable.
        NFS_FS = off;
        NFSD = off;
        SUNRPC = off;
        F2FS_FS = off;
        UDF_FS = off;
        ZRAM = off;

        # Networking beyond a single virtio NIC on DHCP. The firewall is
        # disabled, so netfilter has no consumer.
        NETFILTER = off;
        IP_VS = off;
        INET_DIAG = off;
        NET_SCHED = off;
        NETCONSOLE = off;
        BONDING = off;
        HAMRADIO = off;
        TLS = off;
        VLAN_8021Q = off;
        WIRELESS = off;
        TUN = module;
        RFKILL = off;

        IOSCHED_BFQ = off;

        # Nested virtualization: the guest exposes /dev/kvm (epi-63).
        KVM = on;
        KVM_INTEL = on;
        KVM_AMD = on;

        # chrony syncs off the host clock through this refclock (epi-62).
        PTP_1588_CLOCK_KVM = on;

        RANDOMIZE_BASE = off;

        VSOCKETS = off;
        HID_SUPPORT = off;
        DMI_SYSFS = off;
        FW_CFG_SYSFS = off;
        BLK_DEV_LOOP = off;
      };
    }
  );

  configCheck = pkgs.runCommand "epi-kernel-config-check" { } ''
    fail=0
    ${lib.concatMapStringsSep "\n" (sym: ''
      grep -qx 'CONFIG_${sym}=y' ${kernelPackages.kernel.configfile} \
        || { echo "expected CONFIG_${sym}=y"; fail=1; }
    '') required.y}
    ${lib.concatMapStringsSep "\n" (sym: ''
      grep -qx 'CONFIG_${sym}=m' ${kernelPackages.kernel.configfile} \
        || { echo "expected CONFIG_${sym}=m"; fail=1; }
    '') required.m}
    ${lib.concatMapStringsSep "\n" (sym: ''
      grep -qE '^CONFIG_${sym}=[ym]' ${kernelPackages.kernel.configfile} \
        && { echo "expected CONFIG_${sym} unset"; fail=1; }
    '') required.n}
    [ $fail -eq 0 ] || { echo "guest kernel config assertion failed"; exit 1; }
    touch $out
  '';
in
kernelPackages.extend (_: _: { epiConfigCheck = configCheck; })
