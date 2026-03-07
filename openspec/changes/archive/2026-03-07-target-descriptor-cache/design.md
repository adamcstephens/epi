## Context

`vm_launch.ml` has grown to ~980 lines containing descriptor types, nix eval, artifact validation, disk handling, passt/networking, seed ISO generation, VM launch, and serial console — all in one file. This makes it hard to navigate and creates coupling between concerns that have different change rates.

Every `epi up` invocation runs `nix eval` to resolve the target descriptor (kernel, disk, initrd, cmdline, cpus, memory_mib). For unchanged targets this is pure waste: nix store paths are immutable and content-addressed, so a cached descriptor is valid as long as all its paths exist on disk.

Already-running instances are already short-circuited in `epi.ml` before `provision` is called — the cache is only relevant for the actual provision path.

## Goals / Non-Goals

**Goals:**
- Split `vm_launch.ml` into `target.ml`, `vm_launch.ml`, `console.ml` with clear responsibilities
- Cache descriptors by SHA256(target string) in `~/.local/state/epi/targets/`
- Skip eval+build when cache is valid (all artifact paths exist on disk)
- `--rebuild` flag on `epi up` to bust cache and force re-eval+build

**Non-Goals:**
- TTL-based or flake.lock-based cache invalidation
- Per-instance cache (cache is per-target, shared across instances)
- Changing the descriptor format or the nix eval interface
- Cache invalidation for `EPI_TARGET_RESOLVER_CMD` (user's responsibility)

## Decisions

### Module split

```
target.ml    — descriptor type, parse_key_value_output, find_json_{string,int},
               descriptor_of_output, resolve_descriptor, store_root_of_path,
               ensure_store_realized, build_target_artifact_if_missing,
               is_nix_store_path, descriptor_paths, validate_descriptor,
               validate_descriptor_coherence, all_paths_share_parent,
               split_target, descriptor cache (load/save/validate/bust)

vm_launch.ml — lock_conflict, classify_launch_failure, copy_file,
               ensure_writable_disk, passt_bin, check_passt,
               wait_for_pasta_socket, generate_seed_iso (+ helpers),
               read_ssh_public_keys, launch_detached, provision,
               provision_error type, pp_provision_error

console.ml   — write_all, connect_serial_socket, attach_console,
               console_error type, pp_console_error
```

Utilities (`contains`, `lowercase`, `read_file_if_exists`) move to `target.ml` since that's the primary consumer; `vm_launch.ml` can reference `Target` module for any it needs.

### Cache key

SHA256(target string) via `Digest.string` from OCaml stdlib, encoded as hex. Full hash used as filename — no truncation needed at this scale.

```
~/.local/state/epi/targets/<sha256hex>.descriptor
```

Rationale: hash avoids filesystem-unsafe characters in target strings (`.#`, `/`). Full hex string is unambiguous. No extra dependency.

### Cache format

Key-value, same as the resolver output — reuses existing `descriptor_of_output` parser:

```
kernel=/nix/store/.../bzImage
disk=/nix/store/.../nixos.qcow2
initrd=/nix/store/.../initrd
cmdline=console=ttyS0 root=LABEL=nixos ro
cpus=1
memory_mib=1024
```

Rationale: no new format to maintain, no dependency on a JSON library. `descriptor_of_output` already handles this format.

### Validity check (A+B)

1. Cache file exists for the target hash
2. All paths in the descriptor (`kernel`, `disk`, and `initrd` if present) exist on disk

If either fails → full eval+build+cache. If both pass → skip eval+build, use cached descriptor directly.

Rationale: nix store paths are immutable. If they exist, they are correct. This catches GC'd paths automatically. It does not detect "new build available" — `--rebuild` is the user's escape hatch for that.

### `--rebuild` flag

Added to `epi up`. Deletes the cache file for the target before proceeding, then runs full eval+build+cache. Nix handles build deduplication; we just ensure eval runs and the result is re-cached.

## Risks / Trade-offs

- **Stale cache after flake update** → User must run `epi up --rebuild` after rebuilding. The error path (paths don't exist) is self-healing, so a GC'd store catches it automatically.
- **EPI_TARGET_RESOLVER_CMD with mutable paths** → Paths may exist but be outdated. No solution beyond `--rebuild`. Acceptable: mutable paths are already outside nix's guarantees.
- **Module split merge conflicts** → Split should be done as a single focused commit before other work lands.

## Migration Plan

No migration needed. The cache directory is created on first use. Old installations without a cache simply run eval on the first `up`, then cache from there.
