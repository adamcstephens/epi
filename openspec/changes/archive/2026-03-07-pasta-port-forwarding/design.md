## Context

passt uses NAT networking: the VM gets a DHCP-assigned IP (e.g., 10.143.96.100) that is not routable from the host. All outbound VM traffic is NATted through the host. Inbound connections from host to VM require explicit port forwarding configured on the pasta process at startup via the `-T <host-port>:<vm-port>` flag.

The pasta process is started before cloud-hypervisor in `vm_launch.ml`. Its arguments are fixed at launch time and cannot be changed while the process is running. Port forwarding must therefore be decided at `epi up` time.

## Goals / Non-Goals

**Goals:**
- Forward a host TCP port to VM port 22 so the user can SSH to the VM
- Allocate a free host port at launch time to avoid conflicts between VMs
- Persist the forwarded port in runtime state
- Surface the SSH connection string in `epi up` output and `epi status`

**Non-Goals:**
- Forwarding ports other than SSH (22) — future work
- User-specified port ranges or static port assignment per instance — future work
- UDP forwarding

## Decisions

### Port allocation: bind-to-zero to find a free port

The CLI SHALL bind a TCP socket to `127.0.0.1:0` at launch time, read the OS-assigned ephemeral port, close the socket, then pass that port to pasta via `-T <port>:22`.

**Alternatives considered:**
- *Fixed port (e.g., 2222)*: Simple but breaks with multiple VMs or if port is in use.
- *Configurable port range with sequential scan*: More complex, TOCTOU race between check and pasta bind.
- *Bind-to-zero*: Gives a guaranteed-free port at query time. Minor TOCTOU window between socket close and pasta binding, but in practice negligible for loopback.

### Forwarding SSH only

Initial scope is limited to TCP port 22 (`-T <host-port>:22`). This covers the primary use case (SSH access) with minimal complexity. Additional port mappings can be added as a follow-on change.

### Storage: new `ssh_port` field in runtime TSV

The `instance_store.ml` runtime record gains an `ssh_port : int` field. The TSV gains a 7th column. Rows with 6 columns (written by older epi versions) treat `ssh_port` as absent; reconciliation handles both formats gracefully.

This is consistent with how the `track-pasta-pid` change plans to add `pasta_pid` — both are appended as new trailing TSV columns for backward compatibility.

### Output: connection string printed by `epi up`, shown by `epi status`

After a successful `epi up`, the CLI prints:
```
Instance dev-a running. SSH: ssh -p 2345 root@localhost
```

`epi status` includes the forwarded port alongside PID and other runtime info.

## Risks / Trade-offs

- **TOCTOU race on port allocation**: Between closing the bind-to-zero socket and pasta binding the port, another process could claim the port. In practice this is extremely rare on loopback and is acceptable.
- **pasta exits if port is already in use**: If the TOCTOU race occurs, pasta will exit and `epi up` will fail with `Pasta_socket_unavailable`. The user can retry.
- **No port re-use across restarts**: Each `epi up` allocates a new ephemeral port. Stored connection strings become stale after `epi down`/`epi up` cycles. This is acceptable for dev workflow.

## Open Questions

- Should `epi status` print the full SSH command, or just the port number? (Proposed: full command for convenience.)
- Should the default username in the printed SSH command be hardcoded as `root`, or omitted? (Proposed: omit username, let user's SSH config determine it.)
