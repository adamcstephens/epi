---
# epi-onxl
title: Rename status to info and improve displayed data
status: completed
type: feature
priority: normal
created_at: 2026-03-16T00:45:43Z
updated_at: 2026-03-16T00:45:43Z
---

Rename the `status` subcommand to `info` and significantly expand the information shown.

## Current state

The `status` command shows:
- instance name
- target (flake reference)
- status (running/stopped with dot indicator)
- ssh port (only if running)
- port mappings (host:guest with protocol)
- serial socket path
- disk image path
- unit id (systemd)

## Problems

1. **Missing mounts**: `InstanceState::mounts` is available but never displayed
2. **Missing project dir**: `InstanceState::project_dir` is available but not shown (list shows it, status doesn't)
3. **Inconsistent SSH port display**: `list` shows `127.0.0.1:port` (useful for copy-paste), `status` shows just the port number — should match
4. **No resource info**: CPU count and memory are available from the target descriptor but not shown
5. **No disk size**: Available from config but not displayed
6. **No SSH connection string**: Would be useful to show a copyable `ssh -p PORT user@127.0.0.1` or equivalent
7. **No uptime/PID info**: For running instances, could show process info
8. **Command name**: `status` is ambiguous — `info` better describes "show details about an instance"

## Proposed `info` output

```
instance:   myvm
target:     .#default
project:    /home/user/myproject
status:     ● running

resources:
  cpus:     4
  memory:   2048 MiB
  disk:     40G

network:
  ssh:      ssh -p 2222 user@127.0.0.1
  ports:    8080:80 (tcp)
            9090:443 (tcp)

mounts:
  /home/user/myproject
  /home/user/shared-data

runtime:
  serial:   /path/to/serial.sock
  disk:     /path/to/disk.img
  unit id:  abc123
```

## Tasks

- Rename `status` subcommand to `info` (update clap definition, help text)
- Add mounts display section
- Add project dir display
- Make SSH port display consistent with list (show as connectable address)
- Add CPU and memory from target descriptor
- Add disk size
- Group output into logical sections (identity, resources, network, mounts, runtime)
- Consider showing a copyable SSH command string
- Update any references/docs that mention `status`

## Close Reason

Implemented: renamed status→info, added resources/mounts/project/ssh-command sections, persisted disk_size in state
