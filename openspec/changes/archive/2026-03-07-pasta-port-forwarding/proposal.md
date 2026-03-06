## Why

VMs launched via passt use NAT networking — the VM's DHCP-assigned IP is not routable from the host. SSH and other inbound connections require explicit TCP port forwarding configured on the pasta process. Without this, there is no host→VM connectivity.

## What Changes

- pasta is started with `-T <host-port>:22` to forward a host port to the VM's SSH port
- A host port is allocated per VM (deterministic or ephemeral) and stored in instance runtime state
- `epi up` prints the SSH port so the user can connect with `ssh -p <port> user@localhost`
- `epi status` reports the forwarded SSH port alongside other instance info

## Capabilities

### New Capabilities

- `pasta-port-forwarding`: pasta is configured with TCP port forwarding arguments; a host port is allocated per VM and forwarded to the VM's SSH port (22); the port is persisted in runtime state and surfaced to the user

### Modified Capabilities

- `vm-provision-from-target`: pasta startup now includes `-T` port forwarding arguments in addition to `--vhost-user --socket`
- `vm-runtime-state-reconciliation`: runtime state includes the forwarded SSH port field; reconciliation handles instances with and without a forwarded port
- `dev-instance-cli`: `epi up` output and `epi status` output include the forwarded SSH port

## Impact

- `lib/vm_launch.ml`: pasta invocation gains `-T <host-port>:22` argument
- `lib/instance_store.ml`: `runtime` type gains `ssh_port : int` field; TSV format gains a 7th column
- `lib/epi.ml`: `up` command prints SSH port after launch; `status` command displays it
- `test/test_epi.ml`: mock pasta updated; new assertions on port forwarding behavior
