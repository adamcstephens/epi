## 1. Modify epi-init to remove hooks and expose state

- [x] 1.1 Change epi-init mount path from tmpdir to `/run/epi-init/epidata` (use `RuntimeDirectory=epi-init` in systemd service config)
- [x] 1.2 Remove hook execution block (first-boot guard, seed ISO hooks loop, Nix-declared hooks) from epi-init script
- [x] 1.3 Remove the tmpdir cleanup trap — epidata mount is now left for the hooks service

## 2. Add epi-init-hooks service

- [x] 2.1 Create `epiInitHooks` script: read username from `/run/epi-init/epidata/epi.json`, exit cleanly if mount missing
- [x] 2.2 Add first-boot guard check (`/var/lib/epi-init-done`) — skip hooks if exists
- [x] 2.3 Add seed ISO hook execution loop reading from `/run/epi-init/epidata/hooks/`
- [x] 2.4 Add Nix-declared hook execution (same `lib.concatStrings`/`mapAttrsToList` pattern)
- [x] 2.5 Create guard file after hooks complete
- [x] 2.6 Unmount epidata ISO and clean up mount point after hooks
- [x] 2.7 Define `epi-init-hooks.service` systemd unit: oneshot, `after = ["epi-init.service" "network-online.target"]`, `wants = ["network-online.target"]`, `before = ["multi-user.target"]`, `wantedBy = ["multi-user.target"]`

## 3. Update specs

- [x] 3.1 Sync delta specs to main specs in `openspec/specs/`

## 4. Test

- [x] 4.1 Run `just test` to verify no unit/CLI regressions
- [x] 4.2 Run e2e tests: `just test-e2e e2e-setup` then remaining e2e groups to verify hooks still execute in a real VM
