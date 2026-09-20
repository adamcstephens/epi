//! Instance-local sparse raw disks converted from the shared qcow2 image.
//!
//! Conversion and growth are staged beside the destination, so a failed
//! first launch cannot leave an incomplete disk for the next launch.
//! The guest grows its partition at boot via `boot.growPartition`.

use anyhow::{Context, Result, bail};
use std::path::Path;

use epi_core::process;
use tempfile::NamedTempFile;

/// Convert qcow2 `source` into a writable sparse raw `dest`, grown to
/// `disk_size` (e.g. "40G"). Existing instance disks are left untouched.
pub fn ensure_writable_disk(source: &Path, dest: &Path, disk_size: &str) -> Result<()> {
    if dest.exists() {
        return Ok(());
    }

    let target_bytes = parse_disk_size(disk_size)?;
    let parent = dest
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let staged = NamedTempFile::new_in(parent)
        .with_context(|| format!("staging writable disk beside {}", dest.display()))?;
    let out = process::run(
        "qemu-img",
        &[
            "convert",
            "-f",
            "qcow2",
            "-O",
            "raw",
            "-S",
            "4k",
            &source.to_string_lossy(),
            &staged.path().to_string_lossy(),
        ],
    )?;
    if !out.success() {
        bail!(
            "qemu-img convert failed for {}: {}",
            source.display(),
            out.stderr
        );
    }

    let current = staged
        .as_file()
        .metadata()
        .context("reading converted disk metadata")?
        .len();
    if target_bytes < current {
        bail!(
            "disk_size {disk_size} is smaller than base image ({current} bytes); shrinking is not supported"
        );
    }
    staged
        .as_file()
        .set_len(target_bytes)
        .with_context(|| format!("resizing writable disk to {disk_size}: {}", dest.display()))?;
    staged
        .persist_noclobber(dest)
        .with_context(|| format!("publishing writable disk: {}", dest.display()))?;
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
    use std::fs;
    use std::io::{Seek, SeekFrom, Write};
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    use std::path::PathBuf;
    use tempfile::TempDir;

    fn qcow2_source(dir: &Path) -> PathBuf {
        let raw = dir.join("source.raw");
        let source = dir.join("source.qcow2");
        let mut file = fs::File::create(&raw).unwrap();
        file.write_all(b"bootsector").unwrap();
        file.set_len(1 << 20).unwrap();
        let output = process::run(
            "qemu-img",
            &[
                "convert",
                "-f",
                "raw",
                "-O",
                "qcow2",
                raw.to_str().unwrap(),
                source.to_str().unwrap(),
            ],
        )
        .unwrap();
        assert!(output.success(), "{}", output.stderr);
        source
    }

    #[test]
    fn converts_qcow2_payload_to_raw() {
        let dir = TempDir::new().unwrap();
        let source = qcow2_source(dir.path());
        let dest = dir.path().join("disk.img");

        ensure_writable_disk(&source, &dest, "8M").unwrap();

        let content = fs::read(&dest).unwrap();
        assert_eq!(&content[..10], b"bootsector");
        assert!(content[10..].iter().all(|byte| *byte == 0));
        let metadata = fs::metadata(&dest).unwrap();
        assert_eq!(metadata.len(), 8 << 20);
        assert!(metadata.blocks() * 512 < 1 << 20, "raw disk must be sparse");
    }

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
    fn preserves_guest_writes_without_changing_readonly_source() {
        let dir = TempDir::new().unwrap();
        let source = qcow2_source(dir.path());
        let source_content = fs::read(&source).unwrap();
        fs::set_permissions(&source, fs::Permissions::from_mode(0o444)).unwrap();
        let dest = dir.path().join("disk.img");

        ensure_writable_disk(&source, &dest, "1M").unwrap();
        let mut disk = fs::OpenOptions::new().write(true).open(&dest).unwrap();
        disk.seek(SeekFrom::Start(4096)).unwrap();
        disk.write_all(b"guest wrote things").unwrap();
        drop(disk);

        // Existing disks need neither the source nor a valid requested size.
        ensure_writable_disk(&dir.path().join("missing.qcow2"), &dest, "invalid").unwrap();

        let content = fs::read(&dest).unwrap();
        assert_eq!(&content[4096..4114], b"guest wrote things");
        assert_eq!(content.len(), 1 << 20);
        assert_eq!(fs::read(&source).unwrap(), source_content);
    }

    #[test]
    fn invalid_source_leaves_no_disk_and_can_be_retried() {
        let dir = TempDir::new().unwrap();
        let source = dir.path().join("source.qcow2");
        let dest = dir.path().join("disk.img");
        fs::write(&source, b"not a qcow2 image").unwrap();

        assert!(ensure_writable_disk(&source, &dest, "1M").is_err());
        assert!(!dest.exists());

        qcow2_source(dir.path());
        ensure_writable_disk(&source, &dest, "1M").unwrap();
        assert_eq!(&fs::read(&dest).unwrap()[..10], b"bootsector");
    }

    #[test]
    fn rejects_shrinking_without_publishing_disk() {
        let dir = TempDir::new().unwrap();
        let source = qcow2_source(dir.path());
        let dest = dir.path().join("disk.img");

        assert!(ensure_writable_disk(&source, &dest, "1K").is_err());
        assert!(!dest.exists());

        ensure_writable_disk(&source, &dest, "1M").unwrap();
        assert_eq!(fs::metadata(&dest).unwrap().len(), 1 << 20);
        assert_eq!(&fs::read(&dest).unwrap()[..10], b"bootsector");
    }

    #[test]
    fn resize_failure_leaves_no_disk_and_can_be_retried() {
        let dir = TempDir::new().unwrap();
        let source = qcow2_source(dir.path());
        let dest = dir.path().join("disk.img");

        // Valid u64 size, but not representable by the filesystem's signed offset.
        assert!(ensure_writable_disk(&source, &dest, &u64::MAX.to_string()).is_err());
        assert!(!dest.exists());

        ensure_writable_disk(&source, &dest, "1M").unwrap();
        assert_eq!(&fs::read(&dest).unwrap()[..10], b"bootsector");
    }
}
