## REMOVED Requirements

### Requirement: NixOS guest has a systemd generator for virtiofs mounts
**Reason**: Replaced by the `epi-init-service` capability. The epi-init systemd service now handles reading mount paths from `epi.json` on the `epidata` ISO and creating/starting mount units.
**Migration**: Mount unit generation moves from `systemd.generators.epi-mounts` to `epi-init.service`. Mount unit format and virtiofs tag naming (`hostfs-<i>`) remain identical.

### Requirement: Cloud-init does not configure guest mounts
**Reason**: Cloud-init is being removed entirely. This constraint is no longer needed.
**Migration**: No action needed.

### Requirement: Guest user UID matches host when cloud-init manages the user
**Reason**: Replaced by epi-init-service requirements. UID matching is now handled by epi-init reading `user.uid` from `epi.json`.
**Migration**: UID matching behavior is identical; mechanism changes from cloud-init to epi-init.

### Requirement: Seed ISO includes mount path list
**Reason**: The separate `epi-mounts` plain-text file is replaced by the `mounts` array in `epi.json`. Mount paths are now part of the unified JSON format.
**Migration**: Mount paths move from `epi-mounts` (one path per line) to `epi.json` `mounts` array. Host-side writes JSON; guest-side reads with `jq`.
