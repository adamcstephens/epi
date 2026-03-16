---
# epi-qi99
title: Add multiple port mapping
status: completed
type: task
priority: high
created_at: 2026-03-16T00:45:42Z
updated_at: 2026-03-16T00:45:42Z
---

Add support for multiple TCP port mappings from host to guest, separate from the existing SSH port.

## CLI
- Repeatable --port flag on launch: --port 8080:80 --port :443
- :80 shorthand means auto-allocate ephemeral host port
- 8080:80 means use specific host port

## Config
- ports = ["8080:80", ":443"] in .epi/config.toml
- CLI and config ports are merged (union)

## Runtime storage
- Add ports: Option<Vec<PortMapping>> to Runtime struct
- PortMapping has { host: u16, guest: u16, protocol: String }
- protocol is always "tcp" for now (future: /tcp or /udp suffixes, bare = tcp)

## passt
- Pass additional --tcp-ports args for each mapping alongside existing SSH forwarding
- SSH port remains its own field, untouched

## Display
- Show mapped ports in list/show output

## Close Reason

Implemented multiple port mapping support
