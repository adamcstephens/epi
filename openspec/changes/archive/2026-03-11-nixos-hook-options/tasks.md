## 1. NixOS Module Options

- [x] 1.1 Add `epi.hooks.guest-init`, `epi.hooks.post-launch`, and `epi.hooks.pre-stop` options (type: `attrsOf path`, default: `{}`) to `nix/nixos/epi.nix`
- [x] 1.2 Wire `epi.hooks.post-launch` and `epi.hooks.pre-stop` into the target descriptor output (sorted by key, omit if empty)
- [x] 1.3 Embed `epi.hooks.guest-init` paths into the `epi-init` script — iterate sorted paths after seed ISO hooks section, using same `su -` mechanism

## 2. Host-Side Hook Discovery

- [x] 2.1 Parse optional `hooks` field from target descriptor JSON in OCaml
- [x] 2.2 Extend `Hooks.discover` to accept nix-config hook paths and append them after user + project hooks
- [x] 2.3 Unit test: nix-config hooks are appended at lowest precedence

## 3. Testing

- [x] 3.1 Add manual-test config with a sample `epi.hooks.guest-init` entry and verify it runs on launch
- [x] 3.2 Verify host-side hooks from target descriptor are discovered and executed in correct order
