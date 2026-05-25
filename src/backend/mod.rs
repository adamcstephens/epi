#[cfg(target_os = "linux")]
pub mod ch;

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::fs;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::Duration;

use crate::instance_store;

/// Platform-neutral specification for launching a VM.
///
/// Built by shared orchestration above the backend seam. Contains everything
/// a backend needs to create a VM from already-resolved host state (store
/// paths, overlay locations, auth material).
#[derive(Debug, Clone)]
pub struct LaunchSpec {
    pub id: String,
    pub kernel: PathBuf,
    pub initrd: Option<PathBuf>,
    pub cmdline: String,
    pub root_disk: PathBuf,
    pub epidata: PathBuf,
    pub shares: Vec<SharedDir>,
    pub cpus: u32,
    pub memory_mib: u32,
    pub ssh_pubkey: String,
    pub ssh_port: u16,
    pub port_forwards: Vec<PortMapping>,
    pub disk_size: String,
    pub instance_dir: PathBuf,
}

/// A TCP port forwarded from host to guest. Persisted on `RunningInstance`
/// and threaded through `LaunchSpec` so backends know what to configure.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PortMapping {
    pub host: u16,
    pub guest: u16,
    pub protocol: String,
}

/// A host directory shared into the guest via virtio-fs.
#[derive(Debug, Clone)]
pub struct SharedDir {
    pub tag: String,
    pub host_path: PathBuf,
    pub read_only: bool,
}

/// Where to attach for serial console I/O.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum SerialEndpoint {
    /// Unix-socket serial (cloud-hypervisor on Linux).
    UnixSocket { path: PathBuf },
    /// Pseudo-terminal serial (VZ on macOS). The path is a symlink in the
    /// instance dir pointing at the allocated pty slave.
    Pty { path: PathBuf },
}

/// Handle persisted to the instance store so other epi processes can
/// rediscover and control an already-running VM.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RunningInstance {
    pub id: String,
    pub ssh: SocketAddr,
    pub serial: SerialEndpoint,
    pub backend: BackendState,
    pub disk: String,
    pub ssh_key_path: String,
    #[serde(default)]
    pub ports: Vec<PortMapping>,
}

/// Backend-specific per-instance state. Opaque to shared code; each backend
/// serializes whatever it needs to rediscover its VM from the instance store.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum BackendState {
    CloudHypervisor(ChState),
    // `Vz(VzState)` lands with the macOS backend in Phase 2 (epi-25+).
}

/// Per-instance state for the cloud-hypervisor backend.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChState {
    pub unit_id: String,
}

/// Liveness of an instance as observed by its backend.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InstanceStatus {
    Running,
    Stopped,
}

/// A VMM backend. Shared orchestration builds a [`LaunchSpec`] above the seam
/// and delegates platform-specific work (overlay prep, VMM spawn, supervision)
/// through this trait.
pub trait Backend: Send + Sync {
    /// Prepare host state (overlays, sockets, helpers), launch the VMM, and
    /// return a handle other epi processes can rediscover.
    fn launch(&self, spec: &LaunchSpec) -> Result<RunningInstance>;

    /// Graceful stop with force fallback after `grace`.
    fn stop(&self, instance: &RunningInstance, grace: Duration) -> Result<()>;

    /// Query instance liveness. Used by status reporting and stale-instance
    /// cleanup.
    fn status(&self, instance: &RunningInstance) -> Result<InstanceStatus>;
}

/// Return the backend impl responsible for an existing instance. Dispatch
/// is by the `BackendState` variant on the persisted `RunningInstance`.
pub fn backend_for(rt: &RunningInstance) -> Box<dyn Backend> {
    match &rt.backend {
        #[cfg(target_os = "linux")]
        BackendState::CloudHypervisor(_) => Box::new(ch::CloudHypervisorBackend),
    }
}

/// Whether the given instance is currently running, as observed by its backend.
/// Returns `Ok(false)` if no runtime is recorded for the instance.
pub fn instance_is_running(name: &str) -> Result<bool> {
    let Some(rt) = instance_store::find_runtime(name)? else {
        return Ok(false);
    };
    Ok(backend_for(&rt).status(&rt)? == InstanceStatus::Running)
}

/// Scan all known instances for a running owner of `disk`. Returns the
/// (name, runtime) of the first match. Used to prevent two instances from
/// sharing the same overlay path concurrently.
pub fn find_running_owner_by_disk(disk: &str) -> Result<Option<(String, RunningInstance)>> {
    let dir = instance_store::state_dir();
    if !dir.exists() {
        return Ok(None);
    }
    for entry in fs::read_dir(&dir).with_context(|| format!("reading {}", dir.display()))? {
        let entry = entry?;
        if !entry.file_type()?.is_dir() {
            continue;
        }
        let name = entry.file_name().to_string_lossy().to_string();
        if let Some(state) = instance_store::load_state(&name)?
            && let Some(rt) = state.runtime
            && rt.disk == disk
            && backend_for(&rt).status(&rt)? == InstanceStatus::Running
        {
            return Ok(Some((name, rt)));
        }
    }
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn serial_endpoint_unix_socket_roundtrip() {
        let se = SerialEndpoint::UnixSocket {
            path: PathBuf::from("/tmp/serial.sock"),
        };
        let json = serde_json::to_string(&se).unwrap();
        assert!(json.contains(r#""kind":"unix_socket""#));
        let parsed: SerialEndpoint = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed, se);
    }

    #[test]
    fn serial_endpoint_pty_roundtrip() {
        let se = SerialEndpoint::Pty {
            path: PathBuf::from("/tmp/pty"),
        };
        let json = serde_json::to_string(&se).unwrap();
        assert!(json.contains(r#""kind":"pty""#));
        let parsed: SerialEndpoint = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed, se);
    }

    #[test]
    fn backend_state_cloud_hypervisor_roundtrip() {
        let bs = BackendState::CloudHypervisor(ChState {
            unit_id: "abc123".into(),
        });
        let json = serde_json::to_string(&bs).unwrap();
        assert!(json.contains(r#""kind":"cloud_hypervisor""#));
        assert!(json.contains(r#""unit_id":"abc123""#));
        let parsed: BackendState = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed, bs);
    }

    #[test]
    fn running_instance_roundtrip() {
        let ri = RunningInstance {
            id: "myvm".into(),
            ssh: "127.0.0.1:2222".parse().unwrap(),
            serial: SerialEndpoint::UnixSocket {
                path: PathBuf::from("/tmp/s.sock"),
            },
            backend: BackendState::CloudHypervisor(ChState {
                unit_id: "u1".into(),
            }),
            disk: "/inst/disk.img".into(),
            ssh_key_path: "/inst/id_ed25519".into(),
            ports: vec![],
        };
        let json = serde_json::to_string(&ri).unwrap();
        let parsed: RunningInstance = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed, ri);
    }

    #[test]
    fn running_instance_ipv6_ssh_roundtrip() {
        let ri = RunningInstance {
            id: "v6vm".into(),
            ssh: "[::1]:22".parse().unwrap(),
            serial: SerialEndpoint::Pty {
                path: PathBuf::from("/var/run/epi/v6vm/pty"),
            },
            backend: BackendState::CloudHypervisor(ChState {
                unit_id: "u2".into(),
            }),
            disk: "/inst/disk.img".into(),
            ssh_key_path: "/inst/id_ed25519".into(),
            ports: vec![PortMapping {
                host: 8080,
                guest: 80,
                protocol: "tcp".into(),
            }],
        };
        let json = serde_json::to_string(&ri).unwrap();
        let parsed: RunningInstance = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed, ri);
    }
}
