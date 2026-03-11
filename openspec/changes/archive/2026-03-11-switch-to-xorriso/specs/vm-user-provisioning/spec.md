## MODIFIED Requirements

### Requirement: epi generates an epidata seed ISO
The system SHALL generate a seed ISO at provision time containing `epi.json` derived from the host environment. The ISO SHALL be labeled `epidata` and contain a single JSON file.

The `Vm_launch` module SHALL expose seed generation functions for direct testing:
- `generate_epi_json` — returns the epi.json content as a JSON string
- `read_ssh_public_keys` — returns a list of SSH public key strings from the configured directory

#### Scenario: Seed ISO created during provisioning
- **WHEN** `epi launch` provisions a new instance
- **THEN** epi creates an `epi.json` file with hostname, user info (name, uid, SSH keys), and mount paths
- **AND** epi invokes `xorriso -as mkisofs` to produce an ISO labeled `epidata` from this file
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

#### Scenario: xorriso binary overridable via environment
- **WHEN** `EPI_XORRISO_BIN` is set to a custom path
- **THEN** epi uses that path instead of the default `xorriso` binary for ISO generation

#### Scenario: missing xorriso produces clear error
- **WHEN** xorriso is not found on PATH and `EPI_XORRISO_BIN` is not set
- **THEN** epi reports an error indicating xorriso is missing and suggests installing the `xorriso` package
