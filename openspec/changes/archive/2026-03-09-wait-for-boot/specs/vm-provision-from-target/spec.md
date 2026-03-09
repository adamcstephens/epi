## ADDED Requirements

### Requirement: Provisioning generates an SSH keypair unconditionally
The provisioning flow SHALL always generate an ed25519 SSH keypair for the instance. The generated public key SHALL be included in the cloud-init `ssh_authorized_keys` alongside any user keys from `~/.ssh/*.pub`. The `ssh_key_path` in the returned runtime SHALL always be populated (non-optional).

#### Scenario: SSH key is generated on every launch
- **WHEN** a user runs `epi launch dev-a --target .#dev-a`
- **THEN** an ed25519 keypair is generated at the instance state directory
- **AND** the generated public key is added to cloud-init authorized_keys
- **AND** the runtime `ssh_key_path` is set to the private key path

#### Scenario: Existing key is regenerated on relaunch
- **WHEN** a user runs `epi launch dev-a --target .#dev-a` and instance `dev-a` already has a generated keypair
- **THEN** the old keypair is removed and a fresh one is generated

### Requirement: Provisioning waits for SSH connectivity by default
After successfully launching the VM process, the provisioning flow SHALL poll SSH connectivity by running `ssh ... true` against the forwarded SSH port using the generated key. Polling SHALL continue until SSH responds successfully or the timeout is reached. The default timeout is 120 seconds.

#### Scenario: VM boots and SSH becomes reachable
- **WHEN** `epi launch dev-a --target .#dev-a` successfully starts the VM
- **AND** the guest SSH daemon becomes reachable within the timeout
- **THEN** the command exits zero
- **AND** the CLI prints a message indicating SSH is ready

#### Scenario: SSH wait times out
- **WHEN** `epi launch dev-a --target .#dev-a` successfully starts the VM
- **AND** SSH does not become reachable within the timeout
- **THEN** the command exits non-zero
- **AND** the error states that the SSH wait timed out
- **AND** the error includes the timeout duration

#### Scenario: Progress message during wait
- **WHEN** `epi launch dev-a --target .#dev-a` enters the SSH wait phase
- **THEN** the CLI prints a message indicating it is waiting for SSH with the timeout value

### Requirement: --no-wait skips SSH connectivity polling
The `epi launch` command SHALL accept a `--no-wait` flag that skips the SSH polling phase and returns immediately after the VM process is verified running (previous behavior).

#### Scenario: --no-wait returns immediately
- **WHEN** a user runs `epi launch dev-a --target .#dev-a --no-wait`
- **THEN** the command returns after the VM process is verified running
- **AND** no SSH polling is performed
- **AND** an SSH keypair is still generated

### Requirement: --wait-timeout configures SSH wait duration
The `epi launch` command SHALL accept a `--wait-timeout` flag that sets the maximum number of seconds to wait for SSH. The `EPI_WAIT_TIMEOUT_SECONDS` environment variable SHALL override the default when `--wait-timeout` is not passed.

#### Scenario: Custom timeout via flag
- **WHEN** a user runs `epi launch --target .#dev-a --wait-timeout 60`
- **THEN** the SSH polling phase uses a 60-second timeout

#### Scenario: Custom timeout via environment variable
- **WHEN** `EPI_WAIT_TIMEOUT_SECONDS=30` is set and no `--wait-timeout` flag is passed
- **THEN** the SSH polling phase uses a 30-second timeout

#### Scenario: Flag takes precedence over environment variable
- **WHEN** `EPI_WAIT_TIMEOUT_SECONDS=30` is set and `--wait-timeout 90` is passed
- **THEN** the SSH polling phase uses a 90-second timeout

## MODIFIED Requirements

### Requirement: Up returns actionable stage-specific errors
When provisioning fails, `epi launch` MUST return an error message that identifies the failure stage and the relevant context.

#### Scenario: Target evaluation fails
- **WHEN** target evaluation fails for `epi launch dev-a --target .#dev-a`
- **THEN** the command exits non-zero
- **AND** the error states that target resolution failed
- **AND** the error includes the failing target string

#### Scenario: VM launch fails
- **WHEN** cloud-hypervisor returns a non-zero exit for `epi launch dev-a --target .#dev-a`
- **THEN** the command exits non-zero
- **AND** the error states that VM launch failed
- **AND** the error includes the cloud-hypervisor exit status

#### Scenario: pasta binary is missing
- **WHEN** the pasta binary is not found on PATH and `EPI_PASTA_BIN` is not set
- **THEN** `epi launch` exits non-zero
- **AND** the error states that pasta was not found
- **AND** the error suggests installing the `passt` package or setting `EPI_PASTA_BIN`

#### Scenario: pasta socket is unavailable
- **WHEN** pasta is started but its vhost-user socket does not become available within the timeout
- **THEN** `epi launch` exits non-zero
- **AND** the error states that the pasta socket did not become ready
- **AND** cloud-hypervisor is not started

#### Scenario: seed ISO generation fails due to missing genisoimage
- **WHEN** `genisoimage` is not found on `$PATH` and `EPI_GENISOIMAGE_BIN` is not set
- **THEN** `epi launch` exits non-zero
- **AND** the error states that `genisoimage` was not found
- **AND** the error suggests installing `cdrkit` or setting `EPI_GENISOIMAGE_BIN`

#### Scenario: seed ISO generation fails due to genisoimage error
- **WHEN** `genisoimage` exits non-zero during seed ISO creation
- **THEN** `epi launch` exits non-zero
- **AND** the error includes the stderr output from genisoimage

#### Scenario: virtiofsd binary is missing when mounts are requested
- **WHEN** `--mount` is passed and `virtiofsd` is not found on `$PATH` and `EPI_VIRTIOFSD_BIN` is not set
- **THEN** `epi launch` exits non-zero
- **AND** the error states that `virtiofsd` was not found
- **AND** the error suggests installing the `virtiofsd` package or setting `EPI_VIRTIOFSD_BIN`

#### Scenario: virtiofsd fails to start
- **WHEN** `virtiofsd` starts but exits non-zero
- **THEN** `epi launch` exits non-zero
- **AND** the error includes the stderr output from virtiofsd

#### Scenario: virtiofsd socket does not appear
- **WHEN** virtiofsd is started but its socket does not appear within the timeout
- **THEN** `epi launch` exits non-zero
- **AND** the error states that the virtiofsd socket did not become ready

#### Scenario: mount path is not a directory
- **WHEN** a path passed to `--mount` is not a directory (e.g. a regular file or nonexistent path)
- **THEN** `epi launch` exits non-zero
- **AND** the error states that the path is not a directory
- **AND** the error notes that virtiofsd only supports directory sharing

#### Scenario: disk overlay resize fails
- **WHEN** `qemu-img resize` exits non-zero during disk overlay preparation
- **THEN** `epi launch` exits non-zero
- **AND** the error states that disk resize failed
- **AND** the error includes the stderr output from qemu-img

#### Scenario: disk overlay copy fails
- **WHEN** copying the Nix-store disk to the overlay path fails (e.g. permission error, full disk)
- **THEN** `epi launch` exits non-zero
- **AND** the error states that overlay preparation failed
- **AND** the error includes the OS error details

#### Scenario: disk is already locked by another running instance
- **WHEN** `epi launch qa-1 --target .#qa` resolves a disk already held by running instance `dev-a`
- **THEN** the command exits non-zero before launching any processes
- **AND** the error names `dev-a` as the current holder of the disk lock
- **AND** the error includes `dev-a`'s `unit_id`
- **AND** the error suggests stopping `dev-a` before retrying

#### Scenario: systemd user session is unavailable
- **WHEN** `systemd-run --user` fails because no user session is active (e.g. running via cron or SSH without lingering)
- **THEN** `epi launch` exits non-zero
- **AND** the error states that the systemd user session is unavailable
- **AND** the error suggests running `loginctl enable-linger <user>`

#### Scenario: VM exits immediately after systemd-run returns
- **WHEN** `systemd-run` returns exit 0 (unit created) but the VM service is no longer active after a brief settle period
- **THEN** `epi launch` exits non-zero
- **AND** the error states that the VM exited immediately after start

#### Scenario: SSH wait times out
- **WHEN** the VM launches successfully but SSH does not become reachable within the wait timeout
- **THEN** `epi launch` exits non-zero
- **AND** the error states that the SSH wait timed out
- **AND** the error includes the timeout duration

## REMOVED Requirements

### Requirement: --generate-ssh-key flag
**Reason**: SSH key generation is now unconditional. Every launch generates a keypair.
**Migration**: Remove `--generate-ssh-key` from CLI invocations. Key generation happens automatically.
