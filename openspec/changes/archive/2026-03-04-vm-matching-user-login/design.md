## Context

VMs launched by epi boot into a NixOS system with no user accounts beyond `root` (which has no password set). The serial console works but there's no way to actually log in. The `epi ssh` command exists as a stub. Users need to be able to log in as themselves — with a username matching their host account — to interact with the VM after boot.

The NixOS configuration must remain pure — parameterizing `nix eval` with the host username would break reproducibility. User provisioning must happen at runtime, not at Nix evaluation time.

## Goals / Non-Goals

**Goals:**
- A user account matching the host username exists in the VM after first boot
- The user can log in via serial console without a password prompt blocking them
- SSH is enabled in the VM so `epi ssh` can eventually connect
- The host user's SSH public keys are available in the VM for key-based SSH access
- The NixOS closure remains pure and reproducible across users

**Non-Goals:**
- Implementing the full `epi ssh` command (that's a separate change)
- Multi-user support or user management beyond the single host user
- Security hardening of the VM (this is a local dev tool, not production)

## Decisions

### Decision 1: Use cloud-init with NoCloud datasource for runtime user provisioning

epi generates a cloud-init NoCloud seed ISO at provision time containing `user-data` and `meta-data`. The seed ISO is attached as a second disk to cloud-hypervisor. On first boot, cloud-init reads the seed and creates the user account, injects SSH keys, and configures sudo.

**Rationale:** cloud-init is the standard mechanism for VM instance initialization. The NoCloud datasource requires no network metadata service — just a disk with the right files. NixOS supports cloud-init via `services.cloud-init`. The NixOS closure stays pure because it only declares "enable cloud-init" — the per-user configuration lives in the seed ISO generated at runtime.

**Alternatives considered:**
- Passing username via `nix eval --arg` — rejected because it makes evaluation impure; different users produce different closures.
- Kernel cmdline parameters with a custom systemd service — works but reinvents what cloud-init already does.
- `builtins.getEnv` in Nix — blocked by pure evaluation mode and sandbox.

### Decision 2: Generate NoCloud seed ISO with genisoimage

The seed ISO follows the NoCloud convention: a volume labeled `cidata` containing `user-data` (YAML) and `meta-data` (YAML). epi generates these files in the runtime directory and creates the ISO using `genisoimage`.

**user-data structure:**
```yaml
#cloud-config
users:
  - name: <host-username>
    groups: wheel
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - <key1>
      - <key2>
```

**meta-data structure:**
```yaml
instance-id: <instance-name>
local-hostname: <instance-name>
```

**Rationale:** `genisoimage` (from `cdrkit`) is a small, standard tool available in nixpkgs. The ISO format is what cloud-init's NoCloud datasource expects. The seed ISO is written to the runtime directory alongside other per-instance files.

### Decision 3: Serial console auto-login via cloud-init runcmd

cloud-init's `runcmd` or the NixOS getty configuration will set up auto-login for the created user on the serial console. Since cloud-init creates the user at runtime, getty auto-login must be configured to use whatever user cloud-init provisions.

**Rationale:** For a local dev VM, frictionless console access matters more than login security. The user already has full control over the VM via cloud-hypervisor.

**Implementation:** The NixOS module sets `services.getty.autologinUser` to `root` as a fallback, and cloud-init's `runcmd` updates the getty override to use the provisioned username. Alternatively, set an empty password on the cloud-init user so the login prompt is trivial.

### Decision 4: SSH with authorized keys via cloud-init

The NixOS module enables `services.openssh` with password auth disabled. cloud-init injects the host user's SSH public keys into the created user's `~/.ssh/authorized_keys` via the `ssh_authorized_keys` field in `user-data`.

**Rationale:** Key-based SSH is standard and avoids password management. cloud-init handles the key injection natively. Reading the host's existing `~/.ssh/*.pub` files means no extra setup for the user.

### Decision 5: Networking via virtio-net with cloud-hypervisor

The VM needs network connectivity for SSH access. Cloud-hypervisor supports virtio-net devices. The NixOS module configures DHCP on the virtio-net interface, and `epi up` adds `--net` arguments to the cloud-hypervisor command line.

**Rationale:** Cloud-hypervisor's default TAP-based networking is the simplest path. The host can reach the VM via the TAP interface IP.

## Risks / Trade-offs

- **[Risk] TAP networking requires root or CAP_NET_ADMIN** → cloud-hypervisor can create TAP devices but may need elevated privileges. Mitigation: document the requirement; consider using a pre-created TAP or user-mode networking if available.
- **[Risk] SSH key paths may not exist** → Not all users have SSH keys at `~/.ssh/*.pub`. Mitigation: treat missing keys as non-fatal; the user still gets console access. Log a warning if no SSH keys are found.
- **[Risk] genisoimage must be available** → epi needs `genisoimage` at runtime to create the seed ISO. Mitigation: add `cdrkit` to the dev shell in `flake.nix`; fail with a clear error if the binary is missing.
- **[Trade-off] cloud-init adds boot time** → cloud-init runs on every boot but the NoCloud datasource is fast since there's no network metadata to fetch. First boot is slightly slower; subsequent boots detect the instance has already been initialized.
- **[Trade-off] Auto-login removes authentication** → Acceptable for a local dev VM. The VM is only accessible from the host machine.
