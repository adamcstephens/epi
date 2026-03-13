## MODIFIED Requirements

### Requirement: epi generates an epidata seed ISO
The system SHALL generate a seed ISO at provision time containing `epi.json` derived from the host environment. The ISO SHALL be labeled `epidata` and contain a single JSON file.


#### Scenario: Seed ISO created during provisioning
- **WHEN** `epi launch` provisions a new instance
- **THEN** epi creates an `epi.json` file with hostname, user info (name, uid, SSH keys), and mount paths
- **AND** epi invokes `xorriso -as mkisofs` to produce an ISO labeled `epidata` from this file
- **AND** the seed ISO is written to the runtime directory as `epidata.iso`

#### Scenario: Seed ISO attached to cloud-hypervisor
- **WHEN** cloud-hypervisor is launched for the instance
- **THEN** the seed ISO is attached as an additional `--disk` argument (read-only)
- **AND** the `epi-init` service inside the VM reads the `epidata` ISO and applies the configuration

#### Scenario: missing xorriso produces clear error
- **WHEN** xorriso is not found in PATH
- **THEN** epi exits with an actionable error indicating xorriso is missing and how to resolve it

### Requirement: epi.json structure
The `epi.json` file in the seed ISO SHALL use the following JSON structure:

```json
{
  "hostname": "<instance-name>",
  "user": {
    "name": "<username>",
    "uid": <host_uid>,
    "ssh_authorized_keys": ["<key-1>", "<key-2>"]
  },
  "mounts": ["/path/one", "/path/two"]
}
```

Field rules:
- `hostname` is always present (the instance name)
- `user.name` is always present (the matched username)
- `user.uid` is present only when `user_exists` is false (user not in target's `configured_users`)
- `user.ssh_authorized_keys` is present only when at least one public key was found; omitted entirely when no keys are available
- `mounts` is always included, even when empty (as an empty array `[]`)
- SSH keys come from the generated instance SSH key only

#### Scenario: New user gets uid
- **WHEN** `user_exists` is false (username not in `configured_users`)
- **THEN** `epi.json` includes `user.uid` with the host UID value

#### Scenario: Existing NixOS user omits uid
- **WHEN** `user_exists` is true (username in `configured_users`)
- **THEN** `epi.json` omits `user.uid`
- **AND** only `user.name` and (if keys exist) `user.ssh_authorized_keys` are present
