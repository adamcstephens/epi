## ADDED Requirements

### Requirement: VM launches with pasta-backed userspace networking
The `epi up` command SHALL use pasta to provide network access to VMs without requiring root privileges or CAP_NET_ADMIN on the host.

#### Scenario: VM starts with network access as unprivileged user
- **WHEN** an unprivileged user runs `epi up` with a valid target
- **THEN** the CLI invokes pasta to set up userspace networking
- **AND** the VM boots with a functional virtio-net interface
- **AND** the VM obtains network connectivity via DHCP

### Requirement: Pasta binary path is configurable
The pasta binary path SHALL be configurable via the `EPI_PASTA_BIN` environment variable, defaulting to `pasta` on PATH.

#### Scenario: Default pasta binary
- **WHEN** `EPI_PASTA_BIN` is not set
- **THEN** the CLI locates `pasta` on the system PATH

#### Scenario: Custom pasta binary path
- **WHEN** `EPI_PASTA_BIN` is set to `/custom/path/pasta`
- **THEN** the CLI uses `/custom/path/pasta` as the pasta binary

### Requirement: Missing pasta binary produces actionable error
When the pasta binary is not found, the CLI SHALL report an error identifying the missing dependency and how to resolve it.

#### Scenario: Pasta binary not found
- **WHEN** a user runs `epi up` and the pasta binary is not on PATH
- **AND** `EPI_PASTA_BIN` is not set
- **THEN** the command exits non-zero
- **AND** the error message identifies `pasta` as the missing binary
- **AND** the error suggests setting `EPI_PASTA_BIN` or installing the `passt` package
