## MODIFIED Requirements

### Requirement: epi generates an epidata seed ISO
The system SHALL generate a seed ISO at provision time containing `epi.json` derived from the host environment. The ISO SHALL be labeled `epidata` and contain a single JSON file.

The `Vm_launch` module SHALL expose seed generation functions for direct testing:
- `generate_epi_json` — returns the epi.json content as a JSON string
- `read_ssh_public_keys` — returns a list of SSH public key strings from the configured directory

#### Scenario: Seed ISO created during provisioning
- **WHEN** `epi launch` provisions a new instance
- **THEN** epi creates an `epi.json` file with hostname, user info (name, uid, SSH keys), and mount paths
- **AND** epi invokes `genisoimage` to produce an ISO labeled `epidata` from this file
- **AND** the seed ISO is written to the runtime directory as `epidata.iso`

#### Scenario: Seed ISO attached to cloud-hypervisor
- **WHEN** cloud-hypervisor is launched for the instance
- **THEN** the seed ISO is attached as an additional `--disk` argument (read-only)
- **AND** the `epi-init` service inside the VM reads the `epidata` ISO and applies the configuration

#### Scenario: generate_epi_json testable in-process
- **WHEN** test code calls `Vm_launch.generate_epi_json` with instance_name, username, ssh_keys, user_exists, host_uid, and mount_paths
- **THEN** the function returns a string containing valid JSON
- **AND** no files are written to disk
- **AND** no subprocesses are spawned

#### Scenario: read_ssh_public_keys testable with custom directory
- **WHEN** test code calls `Vm_launch.read_ssh_public_keys` with `EPI_SSH_DIR` set to a temp directory containing `.pub` files
- **THEN** the function returns the contents of those files as a string list

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
- `mounts` is present only when mount paths were specified; omitted entirely when empty
- Each SSH key is the full contents of one `~/.ssh/*.pub` file; if `--generate-ssh-key` was used, the generated public key is appended after the user's keys

#### Scenario: New user gets uid
- **WHEN** `user_exists` is false (username not in `configured_users`)
- **THEN** `epi.json` includes `user.uid` with the host UID value

#### Scenario: Existing NixOS user omits uid
- **WHEN** `user_exists` is true (username in `configured_users`)
- **THEN** `epi.json` omits `user.uid`
- **AND** only `user.name` and (if keys exist) `user.ssh_authorized_keys` are present
