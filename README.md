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
dune exec epi -- up --target .#manual-test --console
```

For non-interactive serial capture (useful in CI or scripted debugging), set:

```bash
EPI_CONSOLE_NON_INTERACTIVE=1 \
EPI_CONSOLE_CAPTURE_FILE=/tmp/manual-test-console.log \
EPI_CONSOLE_TIMEOUT_SECONDS=30 \
dune exec epi -- up --target .#manual-test --console
```

`epi up --target .#manual-test` expects kernel/initrd/disk to come from coherent
target-built outputs. The manual-test config wires disk from
`config.system.build.images.qemu` instead of a mutable workspace image.

Success criteria:

- The command evaluates and builds successfully.
- Nix prints a `result` symlink pointing at the built system toplevel.

Basic failure triage:

- If `nixosConfigurations.manual-test` is missing, run `nix flake show` and
  confirm the output is present.
- If `epi up --target .#manual-test` fails coherence checks, rebuild the target
  outputs and verify the manual-test `epi.cloudHypervisor` paths still resolve
  into `/nix/store` outputs from the same evaluation.
- If evaluation fails, inspect referenced module paths and flake output wiring
  in `flake.nix`.

## Instance Removal

Use `epi rm` to remove an instance from local state:

```bash
dune exec epi -- rm dev-a
```

If the instance is running, use force removal to terminate it first:

```bash
dune exec epi -- rm --force dev-a
```
