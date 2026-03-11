## ADDED Requirements

### Requirement: Overlay store is opt-in via epi.overlayStore.enable
The NixOS module SHALL provide an `epi.overlayStore.enable` option (default `false`). When enabled, the module SHALL configure the initrd overlayfs, `local-overlay-store` Nix daemon, minimal `image.repart` disk, and disable the bootloader. When disabled, the module SHALL produce the traditional full qcow2 image with GRUB (existing behavior, unchanged). The module SHALL export the value of `epi.overlayStore.enable` as `overlayStore` in the `config.epi` attribute set so it appears in the target descriptor JSON.

#### Scenario: Overlay store disabled by default
- **WHEN** a NixOS configuration enables `epi.enable = true` without setting `epi.overlayStore.enable`
- **THEN** the configuration produces the traditional full qcow2 disk image
- **AND** the descriptor JSON contains `"overlayStore": false`
- **AND** no initrd overlayfs or local-overlay-store configuration is applied

#### Scenario: Overlay store enabled explicitly
- **WHEN** a NixOS configuration sets `epi.overlayStore.enable = true`
- **THEN** the configuration produces a minimal disk image via `image.repart`
- **AND** the descriptor JSON contains `"overlayStore": true`
- **AND** the initrd overlayfs and local-overlay-store configuration are applied

### Requirement: Guest boots with host Nix store as overlayfs lower layer
When `epi.overlayStore.enable` is `true`, the NixOS guest configuration SHALL mount the host's `/nix` directory via virtiofs (tagged `nix-store`) and set up an overlayfs at `/nix/store` using the host store as the read-only lower layer and a writable directory on the guest's root partition as the upper layer. This setup SHALL occur in the initrd via `boot.initrd.postMountCommands`, before `switch_root` to stage-2 init.

#### Scenario: Overlayfs is mounted before stage-2 init
- **WHEN** the guest VM boots with the `nix-store` virtiofs share available
- **THEN** the initrd mounts virtiofs `nix-store` at `/mnt-root/mnt/host/nix` with read-only option
- **AND** the initrd creates `/mnt-root/nix/.store-upper` and `/mnt-root/nix/.store-work` if they do not exist
- **AND** the initrd mounts an overlayfs at `/mnt-root/nix/store` with `lowerdir=/mnt-root/mnt/host/nix/store`, `upperdir=/mnt-root/nix/.store-upper`, `workdir=/mnt-root/nix/.store-work`
- **AND** the NixOS stage-2 init binary (referenced by the kernel cmdline `init=` parameter) is accessible through the merged overlayfs

#### Scenario: Upper layer persists across reboots
- **WHEN** the guest VM reboots
- **THEN** store paths previously built inside the guest are still present in `/nix/.store-upper`
- **AND** the overlayfs remounts with the same upper layer, preserving guest-built store paths

### Requirement: Guest Nix daemon uses local-overlay-store
When `epi.overlayStore.enable` is `true`, the NixOS guest configuration SHALL enable the `local-overlay-store` Nix experimental feature and configure the Nix daemon to use a `local-overlay` store. The lower store SHALL reference the virtiofs-mounted host Nix directory (rooted at `/mnt/host`) and the upper layer SHALL reference `/nix/.store-upper`.

#### Scenario: Nix daemon sees host store paths
- **WHEN** a user runs `nix path-info /nix/store/<some-host-path>` inside the guest
- **THEN** the command succeeds and reports the path as valid
- **AND** the path content is served from the host's store via the overlayfs lower layer

#### Scenario: Nix build reuses host store paths
- **WHEN** a user runs `nix build` inside the guest for a derivation whose dependencies exist in the host store
- **THEN** Nix skips building those dependencies (they are already present in the lower store)
- **AND** only new derivations not present in the host store are built
- **AND** newly built store paths are written to the upper layer (`/nix/.store-upper`)

### Requirement: Guest initrd includes virtiofs and overlay kernel modules
The NixOS guest configuration SHALL include `virtiofs` and `overlay` in `boot.initrd.availableKernelModules` so that both filesystem types are available during initrd execution.

#### Scenario: Required kernel modules available in initrd
- **WHEN** the guest VM boots into the initrd
- **THEN** the `virtiofs` and `overlay` kernel modules are loadable
- **AND** `mount -t virtiofs` and `mount -t overlay` commands succeed

### Requirement: Minimal disk image via image.repart with no store closure
When `epi.overlayStore.enable` is `true`, the NixOS guest configuration SHALL use `image.repart` to produce a disk image containing a single ext4 root partition with only the directory skeleton needed for the overlayfs setup — no Nix store closure, no boot partition, no bootloader. The partition SHALL be labeled `nixos` and use `Minimize = "guess"` for minimal size. The `contents` SHALL create `/nix/.store-upper`, `/nix/.store-work`, and `/mnt/host/nix`. No `storePaths` SHALL be included.

#### Scenario: Disk image contains no store paths
- **WHEN** the minimal disk image is built via `image.repart`
- **THEN** the image does not contain any paths under `/nix/store/`
- **AND** the image size is significantly smaller than the full closure-based image (under 100 MB)

#### Scenario: Disk image has required directory structure
- **WHEN** the minimal disk image is mounted
- **THEN** the directories `/nix/.store-upper`, `/nix/.store-work`, and `/mnt/host/nix` exist
- **AND** the root partition is ext4 labeled `nixos`

### Requirement: Bootloader is disabled
When `epi.overlayStore.enable` is `true`, the NixOS guest configuration SHALL disable the bootloader (`boot.loader.grub.enable = false`) since cloud-hypervisor receives kernel and initrd directly. The disk image SHALL contain no boot partition and no bootloader binaries.

#### Scenario: No bootloader in guest config
- **WHEN** the NixOS guest configuration is evaluated
- **THEN** no bootloader is installed or configured
- **AND** the disk image contains no ESP or GRUB partition

### Requirement: Host conditionally starts virtiofsd for /nix based on descriptor
When the target descriptor's `overlayStore` field is `true`, the `epi launch` command SHALL start a virtiofsd daemon sharing the host's `/nix` directory with the virtiofs tag `nix-store`. This virtiofsd SHALL be started before cloud-hypervisor launches, alongside any user-requested `--mount` shares. The `/nix` share SHALL NOT appear in the instance's `mounts` file (it is not a user-configurable mount). When `overlayStore` is `false`, no nix-store virtiofsd SHALL be started.

#### Scenario: virtiofsd for /nix started when overlayStore is true
- **WHEN** a user runs `epi launch --target .#config` and the descriptor has `overlayStore: true`
- **THEN** a virtiofsd process is started sharing `/nix` with a vhost-user socket in the instance directory
- **AND** cloud-hypervisor receives a `--fs` argument with `tag=nix-store` pointing to that socket
- **AND** the virtiofsd is managed under the instance's systemd slice for cleanup

#### Scenario: No nix-store virtiofsd when overlayStore is false
- **WHEN** a user runs `epi launch --target .#config` and the descriptor has `overlayStore: false`
- **THEN** no virtiofsd is started for `/nix`
- **AND** virtiofsd is only started if `--mount` flags are provided (existing behavior)

#### Scenario: /nix share coexists with user mounts
- **WHEN** a user runs `epi launch --target .#config --mount /home/user/project` and the descriptor has `overlayStore: true`
- **THEN** two virtiofsd processes are started: one for `/nix` (tag `nix-store`) and one for `/home/user/project` (tag `hostfs-0`)
- **AND** cloud-hypervisor receives both `--fs` arguments

#### Scenario: /nix share is not persisted in mounts file
- **WHEN** `epi launch` completes with `overlayStore: true`
- **THEN** the instance's `mounts` file does not contain `/nix`
