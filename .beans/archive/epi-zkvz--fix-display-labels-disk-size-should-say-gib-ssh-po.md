---
# epi-zkvz
title: 'Fix display labels: disk size should say GiB, ssh port should say ssh_port'
status: completed
type: bug
priority: low
created_at: 2026-03-16T00:45:43Z
updated_at: 2026-03-16T00:45:43Z
---

Two display fixes: 1) disk_size values like '40G' should be displayed as GiB to users since qemu-img uses powers of 1024. 2) The info command shows 'ssh' for the port field but should say 'ssh_port'.

## Close Reason

Fixed both display labels in info command
