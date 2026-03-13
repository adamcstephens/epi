## Purpose
Define the pasta userspace networking integration for `epi launch` so VMs obtain network access without requiring root privileges or CAP_NET_ADMIN on the host.

## Requirements

### Requirement: VM launches with pasta-backed userspace networking
The `epi launch` command SHALL use pasta to provide network access to VMs without requiring root privileges or CAP_NET_ADMIN on the host.

#### Scenario: VM starts with network access as unprivileged user
- **WHEN** an unprivileged user runs `epi launch` with a valid target
- **THEN** the CLI invokes pasta to set up userspace networking
- **AND** the VM boots with a functional virtio-net interface
- **AND** the VM obtains network connectivity via DHCP

### Requirement: Missing passt binary produces actionable error
The system SHALL check for `passt` in PATH before attempting to start networking. When the binary is not found, the CLI SHALL exit with an actionable error identifying the missing dependency and how to resolve it.

#### Scenario: Passt binary not found
- **WHEN** a user runs `epi launch` and `passt` is not found in PATH
- **THEN** the command exits non-zero
- **AND** the error message identifies `passt` as the missing binary
- **AND** the error provides an actionable message about how to resolve it
