## ADDED Requirements

### Requirement: Copy files from host to instance
The `epi cp` command SHALL copy files from a local path to a running instance when the destination is prefixed with `<instance>:`.

#### Scenario: Copy a single file to instance
- **WHEN** user runs `epi cp ./file.txt myvm:/tmp/file.txt`
- **THEN** the file is transferred to `/tmp/file.txt` inside the instance `myvm` using rsync over SSH

#### Scenario: Copy a directory to instance
- **WHEN** user runs `epi cp ./mydir myvm:/home/user/mydir`
- **THEN** the directory and its contents are recursively transferred to the instance

### Requirement: Copy files from instance to host
The `epi cp` command SHALL copy files from a running instance to a local path when the source is prefixed with `<instance>:`.

#### Scenario: Copy a single file from instance
- **WHEN** user runs `epi cp myvm:/var/log/syslog ./syslog`
- **THEN** the file is transferred from the instance to the local path `./syslog`

#### Scenario: Copy a directory from instance
- **WHEN** user runs `epi cp myvm:/etc/nginx ./nginx-conf`
- **THEN** the directory and its contents are recursively transferred to the local path

### Requirement: SSH transport reuse
The `epi cp` command SHALL use the instance's existing SSH key, port, and connection options (StrictHostKeyChecking=no, UserKnownHostsFile=/dev/null, LogLevel=ERROR) when invoking rsync.

#### Scenario: rsync uses instance SSH credentials
- **WHEN** user runs `epi cp ./file myvm:/tmp/file`
- **THEN** rsync is invoked with `-e "ssh -i <key> -p <port> -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"`

### Requirement: Instance must be running
The `epi cp` command SHALL fail with an error if the target instance is not running or has no SSH port.

#### Scenario: Instance not running
- **WHEN** user runs `epi cp ./file stopped-vm:/tmp/file`
- **AND** instance `stopped-vm` is not running
- **THEN** the command fails with an error message indicating the instance is not running

### Requirement: Progress display
rsync SHALL be invoked with `--progress` so transfer progress is visible to the user.

#### Scenario: Progress shown during transfer
- **WHEN** user runs `epi cp ./largefile myvm:/tmp/largefile`
- **THEN** rsync displays transfer progress on the terminal

### Requirement: Default instance
The instance name SHALL default to `default` when the remote path prefix does not match a running instance name, consistent with other epi commands.

#### Scenario: Default instance used
- **WHEN** user runs `epi cp ./file :~/file`
- **THEN** the file is copied to the instance named `default`

### Requirement: rsync available on host and guest
rsync SHALL be available in the host wrapper PATH and in the guest NixOS image's system packages.

#### Scenario: Host has rsync
- **WHEN** epi is installed via the Nix wrapper
- **THEN** `rsync` is on the wrapper's PATH

#### Scenario: Guest has rsync
- **WHEN** a VM is launched with the epi NixOS module enabled
- **THEN** `rsync` is available inside the guest
