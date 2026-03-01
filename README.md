# epi

## Manual NixOS Configuration Test

This repository exposes a manual test configuration at:

- `nixosConfigurations.manual-test`

Use the following command to validate the configuration wiring without switching
your running system:

```bash
nix build .#nixosConfigurations.manual-test.config.system.build.toplevel
```

To test `epi up` target resolution/launch input wiring:

```bash
dune exec epi -- up --target .#manual-test
```

Note: this manual-test target currently points at a local workspace disk image
(`/home/adam/projects/epi/nixos.img`) for writable VM disk access.

Success criteria:

- The command evaluates and builds successfully.
- Nix prints a `result` symlink pointing at the built system toplevel.

Basic failure triage:

- If `nixosConfigurations.manual-test` is missing, run `nix flake show` and
  confirm the output is present.
- If evaluation fails, inspect referenced module paths and flake output wiring
  in `flake.nix`.
