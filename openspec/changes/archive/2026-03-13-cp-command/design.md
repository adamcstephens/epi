## Context

epi currently supports SSH and exec commands to running VMs. File transfer requires pre-configuring virtiofs mounts at launch time. The SSH transport (key, port, known-hosts suppression) is already established per instance and reused across `ssh`, `exec`, and hooks.

rsync is not currently present on either the host wrapper PATH or the guest NixOS image.

## Goals / Non-Goals

**Goals:**
- Ad-hoc file copy to/from a running instance with no pre-configuration
- Reuse existing SSH transport for authentication and connectivity
- Support single files, directories, and recursive copy
- Show transfer progress by default

**Non-Goals:**
- Continuous sync / watch mode
- Replacing virtiofs mounts for persistent shared directories
- Supporting copy between two remote instances

## Decisions

### Use rsync as the transfer backend
rsync provides delta transfer, progress display, directory recursion, and permission preservation out of the box. The alternative (scp) is strictly less capable with the same SSH dependency. Since we control both ends via Nix, the dependency is trivially guaranteed.

### Path syntax: `<instance>:<path>`
Follow the scp/rsync convention of `host:path`. The instance name takes the place of the hostname. At least one side must be remote (instance-prefixed). Both sides remote is a non-goal.

Parse rule: split on the first `:` — if the left side matches a running instance name, treat it as remote. Otherwise treat the entire string as a local path. This avoids ambiguity with absolute paths (which start with `/`, never matching an instance name).

### Exec into rsync (like ssh/exec commands)
Use `std::process::Command::exec()` to replace the epi process with rsync, consistent with how `cmd_ssh` and `cmd_exec` work. This gives rsync direct terminal access for progress display and signal handling.

### Pass SSH options via rsync's `-e` flag
rsync accepts `-e "ssh <args>"` to specify the remote shell. Construct the same SSH args used by `cmd_ssh` (key, port, known-hosts suppression) and pass them through `-e`.

## Risks / Trade-offs

- **rsync version skew** — host and guest rsync versions could differ. Mitigation: rsync's wire protocol is backward-compatible across versions. Not a practical concern.
- **Increases guest image size** — rsync adds a dependency to the NixOS closure. Mitigation: rsync is small (~300KB) and already a transitive dependency of many NixOS configs.
