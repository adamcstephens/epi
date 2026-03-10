## MODIFIED Requirements

### Requirement: epi generates a cloud-init NoCloud seed ISO
The system SHALL generate a seed ISO at provision time containing a single `epi.json` file derived from the host environment. The ISO SHALL use the volume label `epidata`. This replaces the previous `cidata` ISO with separate `user-data`, `meta-data`, and `epi-mounts` files.

#### Scenario: Seed ISO created during provisioning
- **WHEN** `epi up` provisions a new instance
- **THEN** epi creates an `epi.json` file with hostname, user data (name, uid, SSH keys), and mount paths
- **AND** epi invokes `genisoimage` to produce an ISO labeled `epidata` containing `epi.json`
- **AND** the seed ISO is written to the instance directory

#### Scenario: Seed ISO attached to cloud-hypervisor
- **WHEN** cloud-hypervisor is launched for the instance
- **THEN** the seed ISO is attached as an additional `--disk` argument (read-only)

### Requirement: cloud-init user-data YAML structure
The `epi.json` file in the seed ISO SHALL use JSON format with the following structure:

```json
{
  "hostname": "<instance-name>",
  "user": {
    "name": "<username>",
    "uid": <host_uid>,
    "ssh_authorized_keys": ["<key1>", "<key2>"]
  },
  "mounts": ["/path1", "/path2"]
}
```

Field rules:
- `hostname` is always emitted (the instance name)
- `user.name` is always emitted (the matching username)
- `user.uid` is emitted only when the username is **not** listed in the target's `configured_users`
- `user.ssh_authorized_keys` is emitted only when at least one public key was found; omitted when no keys are available
- `mounts` is emitted only when `--mount` was used; omitted when no mounts specified
- Each SSH key is the full contents of one `~/.ssh/*.pub` file; if `--generate-ssh-key` was used, the generated public key is appended

#### Scenario: New user gets uid
- **WHEN** the matched username is not in `configured_users`
- **THEN** `epi.json` includes `user.uid` set to the host user's UID

#### Scenario: Existing NixOS user gets only name and keys
- **WHEN** the matched username is already in `configured_users`
- **THEN** `epi.json` contains `user.name` and `user.ssh_authorized_keys` (if keys exist)
- **AND** `user.uid` is omitted

### Requirement: Seed ISO is labeled cidata and uses Joliet+Rock Ridge
The seed ISO SHALL be created with:
- Volume label: `epidata`
- Joliet extensions enabled (`-joliet`)
- Rock Ridge extensions enabled (`-rock`)

The ISO is written to `<instance-dir>/epidata.iso` and passed to cloud-hypervisor as a read-only disk attachment.

#### Scenario: ISO created with epidata label
- **WHEN** epi creates the seed ISO
- **THEN** the ISO volume label is `epidata`
- **AND** the ISO file is named `epidata.iso`

## REMOVED Requirements

### Requirement: Host SSH public keys included in seed
**Reason**: Merged into the modified "cloud-init user-data YAML structure" requirement, which now covers `epi.json` format including SSH keys in the `user.ssh_authorized_keys` array.
**Migration**: SSH key handling is unchanged in behavior; keys move from cloud-config YAML `ssh_authorized_keys` to JSON `user.ssh_authorized_keys` array.

### Requirement: cloud-init meta-data YAML structure
**Reason**: The separate `meta-data` file is replaced by the `hostname` field in `epi.json`. The `instance-id` field is no longer needed since epi-init runs on every boot (no first-boot detection).
**Migration**: Hostname moves from `meta-data` `local-hostname` to `epi.json` `hostname`. No migration needed for `instance-id`.
