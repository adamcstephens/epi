## Purpose
Define how the system caches and reuses resolved target descriptors to avoid redundant nix eval and nix build invocations.

## Requirements

### Requirement: Descriptor cache stores resolved target artifacts
The system SHALL cache the resolved descriptor (kernel, disk, initrd, cmdline, cpus, memory_mib) for each target string in `~/.local/state/epi/targets/<sha256>.descriptor` as key-value text, keyed by SHA256 of the full target string.

#### Scenario: Cache is written after successful resolution
- **WHEN** `epi up --target .#foo` resolves a descriptor via nix eval
- **THEN** the resolved descriptor is written to the cache file before VM launch

#### Scenario: Cache file uses SHA256 of target string as filename
- **WHEN** target string is `.#manual-test`
- **THEN** the cache file is named by the hex SHA256 of that exact string

### Requirement: Descriptor cache is used when valid
The system SHALL skip nix eval and nix build when a cache file exists for the target AND all artifact paths referenced in the cached descriptor exist on disk.

#### Scenario: Cache hit with all paths present
- **WHEN** `epi up --target .#foo` is run and a valid cache file exists with all paths on disk
- **THEN** nix eval is not invoked
- **AND** the cached descriptor is used directly for VM launch

#### Scenario: Cache miss — no file
- **WHEN** `epi up --target .#foo` is run and no cache file exists for the target
- **THEN** nix eval is invoked, the descriptor is resolved, and the cache is written

#### Scenario: Cache miss — path missing from disk
- **WHEN** a cache file exists but one or more artifact paths do not exist on disk
- **THEN** nix eval is invoked, the descriptor is re-resolved, and the cache is overwritten

### Requirement: Cache is bypassed with --rebuild
The `epi up` command SHALL accept a `--rebuild` flag that deletes the cache file for the target and forces full eval and build before launching.

#### Scenario: --rebuild busts cache and re-evaluates
- **WHEN** `epi up --target .#foo --rebuild` is run
- **THEN** any existing cache file for `.#foo` is deleted
- **AND** nix eval is invoked unconditionally
- **AND** the result is cached after successful resolution
