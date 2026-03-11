## Context

epi generates a seed ISO (`epidata.iso`) during VM provisioning using `genisoimage` from the `cdrkit` package. This ISO contains `epi.json` with user/host configuration and is attached read-only to cloud-hypervisor. The genisoimage binary path is overridable via `EPI_GENISOIMAGE_BIN` for testing with mocks.

cdrkit has been unmaintained since 2010. xorriso is actively maintained and available in nixpkgs.

## Goals / Non-Goals

**Goals:**
- Replace genisoimage with xorriso for ISO generation
- Maintain identical ISO output (ISO 9660, Joliet, Rock Ridge, `epidata` volume label)
- Keep the same testing approach (mockable binary via env var)

**Non-Goals:**
- Changing ISO contents, format, or guest-side mounting logic
- Switching to a library-based approach (we still shell out)

## Decisions

**xorriso command syntax**: Use `xorriso -as mkisofs` compatibility mode, which accepts the same flags as genisoimage (`-output`, `-volid`, `-joliet`, `-rock`). This minimizes code changes — only the binary name and package dependency change.

Alternative considered: native xorriso syntax (`-outdev`, `-volid`, `-map`). Rejected because the mkisofs compatibility mode is simpler and keeps the change minimal.

**Env var rename**: `EPI_GENISOIMAGE_BIN` → `EPI_XORRISO_BIN`. Clean break since this is a dev/test-facing variable, not user-facing configuration.

## Risks / Trade-offs

- [xorriso `-as mkisofs` compatibility] → Well-documented and widely used mode; low risk.
- [Breaking env var rename] → Only affects test infrastructure and advanced users overriding the binary. Acceptable for a clean migration.
