## Context

Currently, guest VM initialization uses two separate mechanisms:

1. **cloud-init** — runs once at first boot, creates the user account (username, UID, SSH keys, groups, sudo), sets hostname via NoCloud seed ISO
2. **epi-mounts-generator** — a systemd generator that runs on every boot, reads `epi-mounts` from the cidata ISO, and emits `.mount` units for virtiofs

This split means user creation (cloud-init) and mount setup (generator) have no explicit ordering relationship. The generator runs during systemd's generator phase (before services), while cloud-init runs as a service. If mounts need the user's home directory to exist (for correct ownership), the ordering is implicit and fragile.

The seed ISO currently contains three separate files (`user-data`, `meta-data`, `epi-mounts`) in different formats (cloud-config YAML, YAML, plain text). Since we control both the writer (OCaml host) and reader (guest init), we can unify these into a single JSON file.

## Goals / Non-Goals

**Goals:**
- Replace cloud-init and the epi-mounts generator with a single `epi-init` systemd oneshot service
- Unify the seed ISO into a single `epi.json` file on an ISO labeled `epidata`
- Guarantee user creation completes before virtiofs mounts are attempted
- Maintain all existing functionality: user creation, SSH keys, UID matching, hostname, sudo, virtiofs mounts
- Reduce guest image size by removing cloud-init dependency

**Non-Goals:**
- Changing the host-side launch flow (virtiofsd, cloud-hypervisor args, etc.)
- Changing the seed ISO creation mechanism (genisoimage)
- Supporting any cloud-init features beyond what epi currently uses

## Decisions

### 1. Single JSON file (`epi.json`) on `epidata` ISO

**Decision:** Replace the three separate files (`user-data`, `meta-data`, `epi-mounts`) with a single `epi.json`. Rename the ISO volume label from `cidata` to `epidata`.

Format:
```json
{
  "hostname": "<instance-name>",
  "user": {
    "name": "<username>",
    "uid": 1000,
    "ssh_authorized_keys": ["ssh-ed25519 ..."]
  },
  "mounts": ["/home/user/project", "/home/user/data"]
}
```

Field rules:
- `hostname` is always present
- `user.name` is always present
- `user.uid` is present only when the user is not in `configured_users`
- `user.ssh_authorized_keys` is present only when keys exist (empty array omitted)
- `mounts` is present only when mount paths were specified (empty array omitted)

**Rationale:** One file, one format, one parser. JSON is trivially parsed in both OCaml (Yojson, already a dependency) and bash (`jq`, lightweight). The `epidata` label distinguishes our ISO from cloud-init's `cidata`, making it clear this is not a cloud-init datasource.

### 2. Single systemd oneshot service

**Decision:** Replace both the systemd generator and cloud-init with a single `epi-init.service` that runs as a oneshot before `multi-user.target`.

**Rationale:** A systemd generator cannot create users (it runs too early). A service runs at the right time and can do user creation then mount setup in explicit order. One service is simpler than two separate mechanisms.

### 3. Shell script service using jq for JSON parsing

**Decision:** Implement epi-init as a bash script via `pkgs.writeShellApplication`, using `jq` for JSON parsing.

**Rationale:** The operations (blkid, mount, useradd, mkdir, hostname) are shell commands. `jq` is lightweight and standard for JSON in shell scripts. `writeShellApplication` provides shellcheck validation and clean PATH setup.

### 4. epi-init runs on every boot (idempotent)

**Decision:** epi-init runs on every boot. User creation is idempotent (`useradd` only if user doesn't exist), hostname is set every time, mounts are set up every time.

**Rationale:** This is what the generator already does for mounts. No "first boot" detection needed. The service is fast (< 1 second).

### 5. Mount units emitted and started by epi-init

**Decision:** epi-init creates `.mount` unit files in `/run/systemd/system/`, runs `systemctl daemon-reload`, then starts them.

**Rationale:** More explicit than the generator approach of symlinking into `multi-user.target.wants`. The service controls exactly when mounts happen — after user creation.

### 6. Service ordering

**Decision:** `epi-init.service` runs `After=local-fs.target` and `Before=multi-user.target sshd.service`. `Type=oneshot` with `RemainAfterExit=yes`. `WantedBy=multi-user.target`.

**Rationale:** Needs local filesystems for useradd. Must complete before SSH (so user and keys exist). `RemainAfterExit=yes` lets dependent services track completion.

## Risks / Trade-offs

- **[Risk] jq dependency in guest** → Mitigation: `jq` is small (~1MB) and commonly available in NixOS. Far smaller than cloud-init.
- **[Risk] useradd behavior differences across NixOS versions** → Mitigation: Using basic flags (-m, -u, -G, -s) that are stable.
- **[Risk] Mount units created by service not picked up by systemd** → Mitigation: `systemctl daemon-reload` then `systemctl start` is a well-documented pattern.
- **[Trade-off] Losing cloud-init compatibility** → Acceptable: epi VMs are purpose-built. No external tooling depends on cloud-init.
- **[Trade-off] Renaming ISO label breaks existing instances** → Acceptable: Existing instances can be recreated. The label change is a clean break.
