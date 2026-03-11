## Context

epi supports file-based hook scripts at two layers: user (`~/.config/epi/hooks/`) and project (`.epi/hooks/`). Users building NixOS VM configurations in flakes currently have no way to declare hooks within their Nix config — they must maintain separate script files.

The NixOS module (`nix/nixos/epi.nix`) already exposes VM configuration options (kernel, disk, cpus, etc.) that the host reads from the target descriptor. Hooks can follow the same pattern.

## Goals / Non-Goals

**Goals:**
- Allow NixOS module users to declare guest-init, post-launch, and pre-stop hooks as Nix expressions
- Nix-declared hooks have lowest precedence (user > project > nix-config)
- Minimal changes to existing hook infrastructure

**Non-Goals:**
- Changing the file-based hook system
- Adding new hook points beyond the three already defined
- Per-instance hook configuration in Nix (Nix config applies to the target, not a specific instance)

## Decisions

### Hook option structure: attrset of name → path

```nix
epi.hooks.guest-init = {
  "setup-tunnel.sh" = lib.getExe pkgs.somepackage;
  "seed-db.sh" = pkgs.writeShellScript "seed-db" "mix ecto.migrate";
};
```

Type: `lib.types.attrsOf lib.types.path`. Keys are script names (used for ordering), values are store paths. This matches Nix idioms and keeps ordering explicit via lexical sort of keys.

**Alternative**: List of paths — rejected because it loses the naming/ordering contract.

### Host hooks passed via target descriptor JSON

The target descriptor already carries kernel, disk, etc. We add an optional `hooks` field:

```json
{
  "hooks": {
    "post-launch": ["/nix/store/...-setup.sh"],
    "pre-stop": ["/nix/store/...-cleanup.sh"]
  }
}
```

The OCaml host reads these paths and appends them after user + project hooks during discovery. This keeps the Nix module as a data source and the OCaml code as the executor.

### Guest hooks embedded via epi-init script

Guest-init hooks from Nix config are already inside the VM image (they're Nix store paths). The `epi-init` service runs them after the file-based guest hooks from the seed ISO. No need to copy them to the ISO — they're available in the VM's Nix store.

The epi-init script gets a new section that iterates over a known path list, either hardcoded into the script at build time or read from a marker file.

**Decision**: Hardcode paths into the epi-init script at build time via Nix string interpolation. This avoids adding another data file and keeps the mechanism simple.

## Risks / Trade-offs

- [Nix store paths in target descriptor are host paths] → Host-side hooks (post-launch, pre-stop) run on the host, so host-accessible Nix store paths work. Guest-init hooks are baked into the VM image, so they reference guest store paths — no cross-boundary issue.
- [Ordering between file-based and nix hooks is implicit] → Documented as lowest precedence. Users who need fine-grained ordering should use file-based hooks with numeric prefixes.
