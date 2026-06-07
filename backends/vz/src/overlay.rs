//! Writable disk overlays via APFS clonefile.
//!
//! Mirrors the contract of the Linux backend's `ensure_writable_disk`:
//! idempotent, and grows the virtual disk to the requested size on
//! creation. The base image is raw (the NixOS module emits `.raw`), so
//! growing is a plain truncate — the guest grows the partition at boot via
//! `boot.growPartition`.

use anyhow::{Context, Result, bail};
use std::fs;
use std::path::Path;

use epi_core::process;

/// Create `dest` as a writable overlay of `source` if it doesn't exist,
/// grown to `disk_size` (qemu-img style, e.g. "40G"). No-op when `dest`
/// already exists.
pub fn ensure_writable_disk(source: &Path, dest: &Path, disk_size: &str) -> Result<()> {
    if dest.exists() {
        return Ok(());
    }

    clone_or_copy(source, dest)?;

    let target_bytes = parse_disk_size(disk_size)?;
    let current = fs::metadata(dest)
        .with_context(|| format!("reading overlay metadata: {}", dest.display()))?
        .len();
    if target_bytes < current {
        bail!(
            "disk_size {disk_size} is smaller than base image ({current} bytes); shrinking is not supported"
        );
    }
    fs::OpenOptions::new()
        .write(true)
        .open(dest)
        .and_then(|f| f.set_len(target_bytes))
        .with_context(|| format!("resizing overlay to {disk_size}: {}", dest.display()))?;
    Ok(())
}

/// `/bin/cp -c` clones via clonefile(2) on APFS — absolute path because a
/// nix devshell puts GNU cp (no `-c`) first in PATH. The nix store usually
/// lives on its own APFS volume and clonefile can't cross volumes, so fall
/// back to a regular copy when cloning fails.
fn clone_or_copy(source: &Path, dest: &Path) -> Result<()> {
    let out = process::run(
        "/bin/cp",
        &["-c", &source.to_string_lossy(), &dest.to_string_lossy()],
    )?;
    if out.success() {
        return Ok(());
    }
    fs::copy(source, dest).with_context(|| {
        format!(
            "copying base image {} to {}",
            source.display(),
            dest.display()
        )
    })?;
    Ok(())
}

/// Parse a qemu-img style size ("40G", "512M", bare bytes) into bytes.
/// Suffixes are powers of 1024.
fn parse_disk_size(size: &str) -> Result<u64> {
    let size = size.trim();
    if size.is_empty() {
        bail!("empty disk size");
    }
    let (number, multiplier): (&str, u64) = match size.chars().last() {
        Some(c) if c.is_ascii_digit() => (size, 1),
        Some('K') => (&size[..size.len() - 1], 1 << 10),
        Some('M') => (&size[..size.len() - 1], 1 << 20),
        Some('G') => (&size[..size.len() - 1], 1 << 30),
        Some('T') => (&size[..size.len() - 1], 1 << 40),
        Some(c) => bail!("unsupported disk size suffix {c:?} in {size:?}"),
        None => bail!("empty disk size"),
    };
    let value: u64 = number
        .parse()
        .with_context(|| format!("invalid disk size {size:?}"))?;
    value
        .checked_mul(multiplier)
        .ok_or_else(|| anyhow::anyhow!("disk size overflows: {size:?}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn parse_disk_size_suffixes() {
        assert_eq!(parse_disk_size("40G").unwrap(), 40 << 30);
        assert_eq!(parse_disk_size("512M").unwrap(), 512 << 20);
        assert_eq!(parse_disk_size("1K").unwrap(), 1024);
        assert_eq!(parse_disk_size("2T").unwrap(), 2 << 40);
        assert_eq!(parse_disk_size("1024").unwrap(), 1024);
    }

    #[test]
    fn parse_disk_size_rejects_garbage() {
        assert!(parse_disk_size("").is_err());
        assert!(parse_disk_size("G").is_err());
        assert!(parse_disk_size("40X").is_err());
        assert!(parse_disk_size("-1G").is_err());
    }

    #[test]
    fn creates_overlay_with_source_content_and_target_size() {
        let dir = TempDir::new().unwrap();
        let source = dir.path().join("base.raw");
        let dest = dir.path().join("disk.img");
        fs::write(&source, b"bootsector").unwrap();

        ensure_writable_disk(&source, &dest, "1M").unwrap();

        let content = fs::read(&dest).unwrap();
        assert_eq!(&content[..10], b"bootsector");
        assert_eq!(content.len(), 1 << 20, "grown to requested size");
    }

    #[test]
    fn idempotent_when_overlay_exists() {
        let dir = TempDir::new().unwrap();
        let source = dir.path().join("base.raw");
        let dest = dir.path().join("disk.img");
        fs::write(&source, b"base").unwrap();
        fs::write(&dest, b"guest wrote things").unwrap();

        ensure_writable_disk(&source, &dest, "1M").unwrap();

        assert_eq!(
            fs::read(&dest).unwrap(),
            b"guest wrote things",
            "existing overlay must not be touched"
        );
    }

    #[test]
    fn rejects_shrinking_below_base_image() {
        let dir = TempDir::new().unwrap();
        let source = dir.path().join("base.raw");
        let dest = dir.path().join("disk.img");
        fs::write(&source, vec![0u8; 4096]).unwrap();

        let err = ensure_writable_disk(&source, &dest, "1K").unwrap_err();
        assert!(err.to_string().contains("shrinking"), "{err}");
    }

    #[test]
    fn missing_source_errors() {
        let dir = TempDir::new().unwrap();
        let source = dir.path().join("does-not-exist.raw");
        let dest = dir.path().join("disk.img");
        assert!(ensure_writable_disk(&source, &dest, "1M").is_err());
    }

    #[test]
    fn overlay_is_independent_of_source() {
        let dir = TempDir::new().unwrap();
        let source = dir.path().join("base.raw");
        let dest = dir.path().join("disk.img");
        fs::write(&source, b"original").unwrap();

        ensure_writable_disk(&source, &dest, "1K").unwrap();

        // Writing the overlay must not affect the base image.
        fs::write(&dest, b"modified").unwrap();
        assert_eq!(fs::read(&source).unwrap(), b"original");
    }
}
