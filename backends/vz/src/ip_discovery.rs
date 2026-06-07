//! Guest IP discovery, epiInit-reported (decision epi-44).
//!
//! The guest gets a dedicated `epistate` virtio-fs share backed by
//! `${instance_dir}/guest-state/`; a guest systemd unit writes its
//! DHCP-assigned IPv4 address to `ip` in that share after the network is
//! up. The host polls for the file after VM start. No ARP/vmnet fallback —
//! if the file never appears we fail rather than guess.

use anyhow::{Context, Result, bail};
use std::fs;
use std::net::Ipv4Addr;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// Mount tag of the epi-internal share; the guest module matches on this.
pub const GUEST_STATE_TAG: &str = "epistate";

/// Host directory backing the `epistate` share.
pub fn guest_state_dir(instance_dir: &Path) -> PathBuf {
    instance_dir.join("guest-state")
}

/// Where the guest reports its IPv4 address.
pub fn ip_file(instance_dir: &Path) -> PathBuf {
    guest_state_dir(instance_dir).join("ip")
}

/// Poll for the guest-reported IP with backoff until `timeout` elapses.
/// An unparseable file is treated as not-yet-written (the guest's write is
/// not atomic).
pub fn wait_for_guest_ip(instance_dir: &Path, timeout: Duration) -> Result<Ipv4Addr> {
    let path = ip_file(instance_dir);
    let deadline = Instant::now() + timeout;
    let mut delay = Duration::from_millis(100);
    loop {
        if let Ok(content) = fs::read_to_string(&path)
            && let Ok(ip) = content.trim().parse::<Ipv4Addr>()
        {
            return Ok(ip);
        }
        if Instant::now() >= deadline {
            break;
        }
        std::thread::sleep(delay.min(deadline.saturating_duration_since(Instant::now())));
        delay = (delay * 2).min(Duration::from_secs(1));
    }
    match fs::read_to_string(&path) {
        Ok(content) => bail!(
            "guest reported an unparseable IP {:?} in {}",
            content.trim(),
            path.display()
        ),
        Err(_) => bail!(
            "guest never reported its IP ({} did not appear within {}s) — \
             guest network failure or epistate share not mounted",
            path.display(),
            timeout.as_secs()
        ),
    }
}

/// Clear a previous boot's report so polling can't return a stale address.
pub fn clear_stale_ip(instance_dir: &Path) -> Result<()> {
    let path = ip_file(instance_dir);
    if path.exists() {
        fs::remove_file(&path).with_context(|| format!("removing stale {}", path.display()))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn returns_ip_already_present() {
        let dir = TempDir::new().unwrap();
        fs::create_dir_all(guest_state_dir(dir.path())).unwrap();
        fs::write(ip_file(dir.path()), "192.168.64.5\n").unwrap();

        let ip = wait_for_guest_ip(dir.path(), Duration::from_secs(1)).unwrap();
        assert_eq!(ip, Ipv4Addr::new(192, 168, 64, 5));
    }

    #[test]
    fn waits_for_ip_written_later() {
        let dir = TempDir::new().unwrap();
        fs::create_dir_all(guest_state_dir(dir.path())).unwrap();
        let path = ip_file(dir.path());

        let writer = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(150));
            fs::write(path, "10.0.0.9").unwrap();
        });

        let ip = wait_for_guest_ip(dir.path(), Duration::from_secs(5)).unwrap();
        writer.join().unwrap();
        assert_eq!(ip, Ipv4Addr::new(10, 0, 0, 9));
    }

    #[test]
    fn times_out_with_clean_error_when_file_never_appears() {
        let dir = TempDir::new().unwrap();
        let err = wait_for_guest_ip(dir.path(), Duration::from_millis(200)).unwrap_err();
        assert!(err.to_string().contains("never reported"), "{err}");
    }

    #[test]
    fn garbage_content_errors_after_timeout() {
        let dir = TempDir::new().unwrap();
        fs::create_dir_all(guest_state_dir(dir.path())).unwrap();
        fs::write(ip_file(dir.path()), "not-an-ip").unwrap();

        let err = wait_for_guest_ip(dir.path(), Duration::from_millis(200)).unwrap_err();
        assert!(err.to_string().contains("unparseable"), "{err}");
    }

    #[test]
    fn clear_stale_ip_removes_old_report() {
        let dir = TempDir::new().unwrap();
        fs::create_dir_all(guest_state_dir(dir.path())).unwrap();
        fs::write(ip_file(dir.path()), "192.168.64.5").unwrap();

        clear_stale_ip(dir.path()).unwrap();
        assert!(!ip_file(dir.path()).exists());

        // Idempotent when nothing to clear.
        clear_stale_ip(dir.path()).unwrap();
    }
}
