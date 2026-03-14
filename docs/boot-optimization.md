# Boot Time Optimization

## Baseline (2026-03-13)

**Total boot to multi-user: ~10.4s** (kernel 1.2s + userspace 9.2s)

### systemd-analyze blame (top offenders)
| Service | Time | Notes |
|---------|------|-------|
| dhcpcd.service | 5.733s | **Critical path** — blocks network-online.target |
| growpart.service | 1.445s | Partition growing |
| dev-vda1.device | 1.261s | Device detection |
| sshd-keygen.service | 1.048s | Generates host keys on every boot |
| epi-init.service | 1.031s | epi guest initialization |
| firewall.service | 683ms | nftables firewall — unnecessary in VM behind passt |
| systemd-udev-trigger.service | 668ms | Coldplug all udev devices |
| resolvconf.service | 378ms | DNS resolver config |
| systemd-timesyncd.service | 371ms | NTP time sync |
| systemd-oomd.service | 356ms | OOM killer |
| systemd-journald.service | 345ms | Journal |

### Critical chain to multi-user.target
```
multi-user.target @9.172s
└─epi-init-hooks.service @9.124s +47ms
  └─network-online.target @9.121s
    └─dhcpcd.service @3.387s +5.733s     ← BOTTLENECK
```

### Critical chain to sshd.service
```
sshd.service +18ms
└─epi-init.service @2.975s +1.031s
  └─basic.target @2.971s
```

Note: sshd starts at ~4s, but SSH won't succeed until networking (dhcpcd) completes.

### Loaded kernel modules: 69
Many unnecessary modules loaded: cfg80211 (wifi),
atkbd/serio (keyboard), vmw_vsock/vmci (VMware), nftables stack, edac_core,
intel_rapl, dm_mod, loop, isofs/cdrom, autofs4, etc.

### Active services: 39

---

## Optimizations Applied

### 1. Replace dhcpcd with systemd-networkd (biggest win)
- **Actual savings: ~4.5s** (dhcpcd 5.7s → networkd-wait-online 1.3s)
- **Why:** dhcpcd dominated the critical path due to ARP probing (~5s) and
  sequential IPv6 negotiation. systemd-networkd acquires DHCP in parallel
  with other boot tasks and doesn't ARP-probe by default.
- **Change:** `networking.useNetworkd = true;` (with `networking.useDHCP = true`)
- **Bonus:** Networking is no longer on the critical path — networkd finishes
  before epi-init, so multi-user.target no longer waits on DHCP.

### 2. Disable firewall
- **Actual savings: ~700ms** (removed from boot entirely)
- **Why:** The VM runs behind passt (user-mode networking). The host controls
  port forwarding — only explicitly mapped ports are reachable. A guest firewall
  is redundant and loads the entire nftables kernel module stack.
- **Change:** `networking.firewall.enable = false;`

### 3. Disable unnecessary services
- **Services disabled:**
  - `getty@` — no VGA/virtual console needed (serial-getty kept for `epi console`)
  - `logrotate` — already disabled before this work

### 4. Blacklist unnecessary kernel modules
- **Actual savings: ~200ms** (69 → ~35 modules loaded)
- **Why:** The default NixOS kernel config auto-loads dozens of modules the VM
  will never use. Each module load adds overhead during boot.
- **Modules blacklisted:** cfg80211/rfkill (wireless), ccp (AMD crypto),
  atkbd/libps2/serio (keyboard), vmw_vsock/vmw_vmci (VMware),
  intel_rapl (power mgmt), edac_core (ECC), evdev/mac_hid (input),
  dmi_sysfs, qemu_fw_cfg, autofs4, dm_mod, loop, efi_pstore,
  vivaldi_fmap, 8021q (VLANs)
- **Kept:** kvm/kvm_amd (nested virt), button/tiny_power_button (ACPI shutdown),
  af_packet (raw sockets), isofs/cdrom (seed ISO)

---

## Results

| Metric | Before | After | Improvement |
|--------|--------|-------|-------------|
| Total boot (kernel + userspace) | ~10.4s | ~5.0s | **52% faster** |
| Kernel boot | 1.2s | 1.2s | — |
| Userspace to multi-user | 9.2s | 3.8s | **5.4s faster** |
| DHCP (critical path) | 5.7s | 1.3s | **4.4s faster** |
| firewall.service | 683ms | removed | **683ms** |

All 13 e2e tests pass (23s, down from 28s).

### New critical chain
```
multi-user.target @4.6s
└─epi-init-hooks.service @4.5s +78ms
  └─epi-init.service @3.6s +852ms
    └─basic.target @3.6s
```
Networking is no longer the bottleneck — epi-init is now the critical path.

---

## Shutdown fixes (2026-03-14)

Two bugs prevented graceful guest shutdown:

### 1. ExecStop script shebang failed in systemd context
- **Symptom:** `shutdown.sh` exited with status 127 — `env: 'sh': No such file or directory`
- **Cause:** `#!/usr/bin/env sh` requires `sh` in PATH, but systemd transient services
  run with a minimal environment where it's not available.
- **Fix:** Resolve `sh` to its absolute nix store path at script generation time
  (e.g. `#!/nix/store/.../bin/sh`), matching how ch-remote/timeout/tail were already
  resolved.

### 2. Stopping the slice bypassed ExecStop
- **Symptom:** `systemctl --user stop` completed in 0.15s — no graceful shutdown.
- **Cause:** `stop_instance` stopped the systemd **slice** (kills all cgroup processes
  immediately) instead of the VM **service** (which triggers ExecStop).
- **Fix:** Stop the VM service first (triggers ACPI power-button → guest shutdown),
  then stop the slice to clean up helper units (passt, virtiofsd).
- **Result:** Graceful shutdown now takes ~7s (ACPI power-button → guest systemd
  shutdown → VM exit → helper cleanup).

### 3. shutdown-vmm exit code
- `shutdown-vmm` returns non-zero when the VM has already exited (successful ACPI
  shutdown). Added `|| true` to prevent spurious service failure status.

---

## Future opportunities

- **Pre-generate SSH host keys:** `sshd-keygen.service` takes ~1s per boot. Host
  keys could be baked into the image or generated during epi-init (saved in the
  overlay).
- **Reduce initrd:** The initrd could be trimmed to only include virtio drivers.
- **Custom kernel config:** A minimal kernel for cloud-hypervisor VMs (virtio-only,
  no USB/sound/graphics/SCSI) could reduce kernel boot time further.
- **Parallel epi-init:** The epi-init script runs sequentially; some operations
  (user creation, SSH key setup) could potentially run in parallel.
