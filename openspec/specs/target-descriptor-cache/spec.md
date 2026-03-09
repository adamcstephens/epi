## Purpose
Define how the system caches and reuses resolved target descriptors to avoid redundant nix eval and nix build invocations.

## Requirements

### Requirement: Descriptor cache stores resolved target artifacts
The system SHALL cache the resolved descriptor (kernel, disk, initrd, cmdline, cpus, memory_mib, configuredUsers) for each target string in `$EPI_CACHE_DIR/targets/<md5>.descriptor` as JSON, keyed by MD5 hex digest of the full target string.

#### Scenario: Cache is written after successful resolution
- **WHEN** `epi launch --target .#foo` resolves a descriptor via nix eval
- **THEN** the resolved descriptor is written to the cache file as a JSON object before VM launch

#### Scenario: Cache file uses MD5 of target string as filename
- **WHEN** target string is `.#manual-test`
- **THEN** the cache file is named by the hex MD5 of that exact string with `.descriptor` extension

#### Scenario: Cache file format is JSON
- **WHEN** a descriptor cache file is written
- **THEN** the file contains a JSON object with keys: `kernel`, `disk`, `initrd`, `cmdline`, `cpus`, `memory_mib`, `configuredUsers`
- **AND** `initrd` SHALL be `null` when no initrd is configured
- **AND** `configuredUsers` SHALL be a JSON array of strings

### Requirement: Descriptor cache is used when valid
The system SHALL skip nix eval and nix build when a cache file exists for the target AND all artifact paths referenced in the cached descriptor exist on disk.

#### Scenario: Cache hit with all paths present
- **WHEN** `epi launch --target .#foo` is run and a valid cache file exists with all paths on disk
- **THEN** nix eval is not invoked
- **AND** the cached descriptor is used directly for VM launch

#### Scenario: Cache miss — no file
- **WHEN** `epi launch --target .#foo` is run and no cache file exists for the target
- **THEN** nix eval is invoked, the descriptor is resolved, and the cache is written

#### Scenario: Cache miss — path missing from disk
- **WHEN** a cache file exists but one or more artifact paths do not exist on disk
- **THEN** nix eval is invoked, the descriptor is re-resolved, and the cache is overwritten

### Requirement: Cache is bypassed with --rebuild
The `epi launch` command SHALL accept a `--rebuild` flag that deletes the cache file for the target and forces full eval and build before launching.

#### Scenario: --rebuild busts cache and re-evaluates
- **WHEN** `epi launch --target .#foo --rebuild` is run
- **THEN** any existing cache file for `.#foo` is deleted
- **AND** nix eval is invoked unconditionally
- **AND** the result is cached after successful resolution
