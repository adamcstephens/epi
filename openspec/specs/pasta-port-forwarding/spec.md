## Purpose
Define how the CLI allocates a host TCP port and configures pasta to forward it to the VM's SSH port, enabling host-to-VM SSH connections.

## Requirements

### Requirement: pasta is started with TCP port forwarding to VM SSH port
When launching a VM, the CLI SHALL allocate a free host TCP port and start pasta with `-T <host-port>:22` so that host-to-VM SSH connections are possible via `localhost:<host-port>`.

#### Scenario: pasta receives port forwarding arguments
- **WHEN** `epi up dev-a --target .#dev-a` is invoked
- **THEN** the CLI allocates a free host TCP port (e.g., 54321)
- **AND** pasta is started with arguments including `--vhost-user`, `--socket <path>`, and `-T 54321:22`

#### Scenario: allocated port is reachable
- **WHEN** the VM is running and pasta is forwarding host port 54321 to VM port 22
- **THEN** a TCP connection to `localhost:54321` is forwarded to the VM's port 22

### Requirement: host SSH port is allocated by binding to an ephemeral port
The CLI SHALL determine the forwarded host port by binding a TCP socket to `127.0.0.1:0`, reading the OS-assigned port number, and closing the socket before passing the port to pasta.

#### Scenario: unique port per VM
- **WHEN** two VMs `dev-a` and `dev-b` are launched concurrently
- **THEN** each VM receives a distinct host port for SSH forwarding
- **AND** both ports are accessible simultaneously
