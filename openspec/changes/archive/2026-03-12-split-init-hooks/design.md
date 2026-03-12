## Context

`epi-init.service` currently handles both core guest initialization (user creation, SSH keys, hostname, mounts) and guest hook execution in a single systemd oneshot service. The service orders itself `after = ["local-fs.target"]` and `before = ["multi-user.target", "sshd.service"]`. Since there's no dependency on `network-online.target`, hooks that need networking fail silently.

The epi-init script in `nix/nixos/epi.nix` is a single bash script that does everything sequentially: mount epidata ISO → read epi.json → create user → set hostname → SSH keys → virtiofs mounts → run hooks (guarded by `/var/lib/epi-init-done`).

## Goals / Non-Goals

**Goals:**
- Guest-init hooks have network connectivity when they execute
- Core init (user, SSH, mounts) remains fast and does not wait for network
- SSH becomes available as early as possible, independent of hook completion
- No changes to hook authoring interface (same directories, same discovery)

**Non-Goals:**
- Adding a new hook phase/point (e.g., `guest-online` vs `guest-init`) — single phase is sufficient
- Changing host-side hook behavior (post-launch, pre-stop)
- Making hooks block SSH startup

## Decisions

### Split into two systemd services in epi.nix

Extract hook execution into `epi-init-hooks.service`, keeping `epi-init.service` for core setup only.

**epi-init.service** (unchanged ordering):
- `after = ["local-fs.target"]`
- `before = ["multi-user.target", "sshd.service"]`
- Handles: mount epidata, read epi.json, user creation, hostname, SSH keys, virtiofs mounts
- Writes username to a state file so hooks service can read it

**epi-init-hooks.service** (new):
- `after = ["epi-init.service", "network-online.target"]`
- `wants = ["network-online.target"]` (ensures networkd wait-online is pulled in)
- `before = ["multi-user.target"]`
- `wantedBy = ["multi-user.target"]`
- Type: oneshot, RemainAfterExit
- Handles: seed ISO hook execution, Nix-declared hook execution, first-boot guard

**Alternative considered**: Adding `network-online.target` to the existing service. Rejected because it would delay SSH availability — the host polls for SSH readiness after launch, and waiting for DHCP + hooks before SSH starts would slow every launch, even when hooks aren't defined.

### Hooks service reads epi.json from the existing mount

epi-init mounts the epidata ISO at `/run/epi-init/epidata` and leaves it mounted. The hooks service reads the username directly from `/run/epi-init/epidata/epi.json` via `jq`, and reads file-based hooks from `/run/epi-init/epidata/hooks/`. After hook execution, the hooks service unmounts the ISO and cleans up.

### First-boot guard stays with hooks

The `/var/lib/epi-init-done` guard file controls "run hooks on first boot only." It moves to `epi-init-hooks.service` since that's what it guards. Core init (user creation, hostname, mounts) still runs on every boot as before — `id` check handles idempotent user creation, hostname is set each boot, virtiofs remounts are fine.

## Risks / Trade-offs

- **[Hooks run after SSH is available]** → Host-side post-launch hooks already work this way. Guest hooks running slightly after SSH is fine since the host `wait_and_run_hooks` mechanism only gates on SSH readiness, not hook completion. If a user needs hooks to complete before interacting, they can use post-launch hooks to poll.

- **[Network-online.target may delay hooks on slow DHCP]** → This only affects hook execution, not SSH availability. Acceptable trade-off since hooks need network by definition.

- **[Two scripts instead of one in epi.nix]** → Modest increase in NixOS module complexity. Mitigated by keeping both scripts simple and in the same file.
