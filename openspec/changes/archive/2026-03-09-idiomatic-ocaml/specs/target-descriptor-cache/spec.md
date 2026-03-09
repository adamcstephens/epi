## MODIFIED Requirements

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
