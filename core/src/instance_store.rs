use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::fs;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::path::PathBuf;

pub use crate::backend::RunningInstance;

use crate::backend::{BackendState, ChState, SerialEndpoint};
use crate::target;

/// Parse a port mapping string like "8080:80" or ":443".
/// Returns (host_port_or_zero, guest_port) — host=0 means auto-allocate.
pub fn parse_port_mapping(s: &str) -> Result<(u16, u16)> {
    let s = s.trim();
    if let Some(rest) = s.strip_prefix(':') {
        let guest: u16 = rest
            .parse()
            .with_context(|| format!("invalid guest port in '{s}'"))?;
        Ok((0, guest))
    } else if let Some((host_str, guest_str)) = s.split_once(':') {
        let host: u16 = host_str
            .parse()
            .with_context(|| format!("invalid host port in '{s}'"))?;
        let guest: u16 = guest_str
            .parse()
            .with_context(|| format!("invalid guest port in '{s}'"))?;
        Ok((host, guest))
    } else {
        anyhow::bail!("invalid port mapping '{s}' — expected HOST:GUEST or :GUEST")
    }
}

fn default_cpus() -> u32 {
    1
}

fn default_memory_mib() -> u32 {
    1024
}

fn default_disk_size() -> String {
    "40G".into()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InstanceState {
    pub target: String,
    #[serde(default)]
    pub runtime: Option<RunningInstance>,
    #[serde(default)]
    pub mounts: Vec<String>,
    #[serde(default)]
    pub project_dir: Option<String>,
    #[serde(default = "default_disk_size")]
    pub disk_size: String,
    #[serde(default = "default_cpus")]
    pub cpus: u32,
    #[serde(default = "default_memory_mib")]
    pub memory_mib: u32,
    #[serde(default)]
    pub port_specs: Vec<String>,
    #[serde(default)]
    pub ssh_extra_config: Vec<String>,
    #[serde(default)]
    pub descriptor: Option<target::Descriptor>,
}

pub fn state_dir() -> PathBuf {
    let path = if let Ok(dir) = std::env::var("EPI_STATE_DIR") {
        PathBuf::from(dir)
    } else if let Ok(home) = std::env::var("HOME") {
        PathBuf::from(home).join(".local/state/epi")
    } else {
        PathBuf::from(".epi-state")
    };
    std::path::absolute(&path).unwrap_or(path)
}

pub fn instance_dir(name: &str) -> PathBuf {
    state_dir().join(name)
}

pub fn instance_path(name: &str, file: &str) -> PathBuf {
    instance_dir(name).join(file)
}

pub fn ensure_instance_dir(name: &str) -> Result<PathBuf> {
    let dir = instance_dir(name);
    fs::create_dir_all(&dir)
        .with_context(|| format!("failed to create instance dir: {}", dir.display()))?;
    Ok(dir)
}

fn state_path(name: &str) -> PathBuf {
    instance_path(name, "state.json")
}

pub fn load_state(name: &str) -> Result<Option<InstanceState>> {
    let path = state_path(name);
    if !path.exists() {
        return Ok(None);
    }
    let content =
        fs::read_to_string(&path).with_context(|| format!("reading {}", path.display()))?;
    let mut value: serde_json::Value =
        serde_json::from_str(&content).with_context(|| format!("parsing {}", path.display()))?;

    let migrated = migrate_legacy_runtime(&mut value, name);

    let state: InstanceState = serde_json::from_value(value)
        .with_context(|| format!("deserializing {}", path.display()))?;

    if migrated {
        let new_content = serde_json::to_string_pretty(&state)?;
        fs::write(&path, new_content).with_context(|| format!("rewriting {}", path.display()))?;
    }

    Ok(Some(state))
}

/// Migrate a pre-epi-17 state.json shape (flat CH/systemd fields on `runtime`)
/// to the tagged `RunningInstance` shape. Returns true if a migration happened.
fn migrate_legacy_runtime(value: &mut serde_json::Value, name: &str) -> bool {
    let Some(runtime) = value.get_mut("runtime") else {
        return false;
    };
    if runtime.is_null() {
        return false;
    }
    let Some(obj) = runtime.as_object_mut() else {
        return false;
    };
    // Legacy shape has flat `unit_id` and lacks the new tagged `backend`.
    if !obj.contains_key("unit_id") || obj.contains_key("backend") {
        return false;
    }

    let unit_id = obj
        .remove("unit_id")
        .and_then(|v| v.as_str().map(String::from))
        .unwrap_or_default();
    let serial_socket = obj
        .remove("serial_socket")
        .and_then(|v| v.as_str().map(String::from))
        .unwrap_or_default();
    let ssh_port = obj.remove("ssh_port").and_then(|v| v.as_u64()).unwrap_or(0) as u16;

    obj.insert("id".into(), json!(name));
    obj.insert("ssh".into(), json!(format!("127.0.0.1:{ssh_port}")));
    obj.insert(
        "serial".into(),
        json!({"kind": "unix_socket", "path": serial_socket}),
    );
    obj.insert(
        "backend".into(),
        json!({"kind": "cloud_hypervisor", "unit_id": unit_id}),
    );
    true
}

pub fn save_state(name: &str, state: &InstanceState) -> Result<()> {
    ensure_instance_dir(name)?;
    let path = state_path(name);
    let content = serde_json::to_string_pretty(state)?;
    fs::write(&path, content).with_context(|| format!("writing {}", path.display()))?;
    Ok(())
}

pub fn canonicalize_mounts(mounts: &[String]) -> Vec<String> {
    mounts
        .iter()
        .map(|m| {
            std::path::Path::new(m)
                .canonicalize()
                .map(|p| p.to_string_lossy().to_string())
                .unwrap_or_else(|_| m.clone())
        })
        .collect()
}

pub fn set_partial_runtime(name: &str, unit_id: &str) -> Result<()> {
    let mut state =
        load_state(name)?.ok_or_else(|| anyhow::anyhow!("instance {name} does not exist"))?;
    state.runtime = Some(RunningInstance {
        id: name.to_string(),
        ssh: SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0),
        serial: SerialEndpoint::UnixSocket {
            path: PathBuf::new(),
        },
        backend: BackendState::CloudHypervisor(ChState {
            unit_id: unit_id.to_string(),
        }),
        disk: String::new(),
        ssh_key_path: String::new(),
        ports: vec![],
    });
    save_state(name, &state)
}

pub fn set_provisioned(
    name: &str,
    runtime: RunningInstance,
    descriptor: Option<target::Descriptor>,
) -> Result<()> {
    let mut state =
        load_state(name)?.ok_or_else(|| anyhow::anyhow!("instance {name} does not exist"))?;
    state.runtime = Some(runtime);
    if let Some(desc) = descriptor {
        state.descriptor = Some(desc);
    }
    save_state(name, &state)
}

pub fn update_descriptor(name: &str, descriptor: target::Descriptor) -> Result<()> {
    let mut state =
        load_state(name)?.ok_or_else(|| anyhow::anyhow!("instance {name} does not exist"))?;
    state.descriptor = Some(descriptor);
    save_state(name, &state)
}

pub fn clear_runtime(name: &str) -> Result<()> {
    if let Some(mut state) = load_state(name)? {
        state.runtime = None;
        save_state(name, &state)?;
    }
    Ok(())
}

pub fn find(name: &str) -> Result<Option<String>> {
    Ok(load_state(name)?.map(|s| s.target))
}

pub fn find_runtime(name: &str) -> Result<Option<RunningInstance>> {
    Ok(load_state(name)?.and_then(|s| s.runtime))
}

pub fn list() -> Result<Vec<(String, String, Option<String>)>> {
    let dir = state_dir();
    if !dir.exists() {
        return Ok(vec![]);
    }
    let mut instances = vec![];
    for entry in fs::read_dir(&dir)? {
        let entry = entry?;
        if entry.file_type()?.is_dir() {
            let name = entry.file_name().to_string_lossy().to_string();
            if let Some(state) = load_state(&name)? {
                instances.push((name, state.target, state.project_dir));
            }
        }
    }
    instances.sort_by(|a, b| {
        let a_has_project = a.2.is_some();
        let b_has_project = b.2.is_some();
        b_has_project.cmp(&a_has_project).then(a.0.cmp(&b.0))
    });
    Ok(instances)
}

pub fn remove(name: &str) -> Result<()> {
    let dir = instance_dir(name);
    if dir.exists() {
        fs::remove_dir_all(&dir)
            .with_context(|| format!("removing instance dir: {}", dir.display()))?;
    }
    Ok(())
}

pub fn console_log_path(name: &str) -> PathBuf {
    instance_path(name, "console.log")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backend::PortMapping;
    use std::path::Path;
    use tempfile::TempDir;

    fn write_state(dir: &Path, name: &str, state: &InstanceState) {
        let inst_dir = dir.join(name);
        fs::create_dir_all(&inst_dir).unwrap();
        let json = serde_json::to_string_pretty(state).unwrap();
        fs::write(inst_dir.join("state.json"), json).unwrap();
    }

    fn read_state(dir: &Path, name: &str) -> Option<InstanceState> {
        let path = dir.join(name).join("state.json");
        if !path.exists() {
            return None;
        }
        let content = fs::read_to_string(path).unwrap();
        Some(serde_json::from_str(&content).unwrap())
    }

    /// Construct a `RunningInstance` for tests with the given unit_id and ssh port.
    fn test_runtime(name: &str, unit_id: &str, ssh_port: u16) -> RunningInstance {
        RunningInstance {
            id: name.to_string(),
            ssh: SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), ssh_port),
            serial: SerialEndpoint::UnixSocket {
                path: PathBuf::from("/s"),
            },
            backend: BackendState::CloudHypervisor(ChState {
                unit_id: unit_id.to_string(),
            }),
            disk: "/d".into(),
            ssh_key_path: "/k".into(),
            ports: vec![],
        }
    }

    #[test]
    fn state_json_roundtrip() {
        let state = InstanceState {
            target: ".#test".into(),
            runtime: Some(test_runtime("vm1", "aabb", 3333)),
            mounts: vec!["/a".into(), "/b".into()],
            project_dir: None,
            disk_size: String::new(),
            cpus: 0,
            memory_mib: 0,
            port_specs: vec![],
            ssh_extra_config: vec![],
            descriptor: None,
        };
        let json = serde_json::to_string(&state).unwrap();
        let parsed: InstanceState = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.target, ".#test");
        assert_eq!(parsed.runtime.unwrap().ssh.port(), 3333);
        assert_eq!(parsed.mounts.len(), 2);
    }

    #[test]
    fn state_without_runtime() {
        let state = InstanceState {
            target: ".#dev".into(),
            runtime: None,
            mounts: vec![],
            project_dir: None,
            disk_size: String::new(),
            cpus: 0,
            memory_mib: 0,
            port_specs: vec![],
            ssh_extra_config: vec![],
            descriptor: None,
        };
        let json = serde_json::to_string(&state).unwrap();
        let parsed: InstanceState = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.target, ".#dev");
        assert!(parsed.runtime.is_none());
    }

    #[test]
    fn state_with_mounts() {
        let state = InstanceState {
            target: ".#dev".into(),
            runtime: None,
            mounts: vec!["/home".into(), "/opt".into()],
            project_dir: None,
            disk_size: String::new(),
            cpus: 0,
            memory_mib: 0,
            port_specs: vec![],
            ssh_extra_config: vec![],
            descriptor: None,
        };
        let json = serde_json::to_string(&state).unwrap();
        let parsed: InstanceState = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.mounts, vec!["/home", "/opt"]);
    }

    #[test]
    fn write_and_read_state_on_disk() {
        let dir = TempDir::new().unwrap();
        let state = InstanceState {
            target: ".#test".into(),
            runtime: None,
            mounts: vec!["/home".into()],
            project_dir: None,
            disk_size: String::new(),
            cpus: 0,
            memory_mib: 0,
            port_specs: vec![],
            ssh_extra_config: vec![],
            descriptor: None,
        };
        write_state(dir.path(), "myvm", &state);

        let loaded = read_state(dir.path(), "myvm").unwrap();
        assert_eq!(loaded.target, ".#test");
        assert!(loaded.runtime.is_none());
        assert_eq!(loaded.mounts, vec!["/home"]);
    }

    #[test]
    fn read_nonexistent_returns_none() {
        let dir = TempDir::new().unwrap();
        assert!(read_state(dir.path(), "nope").is_none());
    }

    #[test]
    fn set_provisioned_preserves_target_and_mounts() {
        let dir = TempDir::new().unwrap();
        let state = InstanceState {
            target: ".#dev".into(),
            runtime: None,
            mounts: vec!["/mnt".into()],
            project_dir: None,
            disk_size: String::new(),
            cpus: 0,
            memory_mib: 0,
            port_specs: vec![],
            ssh_extra_config: vec![],
            descriptor: None,
        };
        write_state(dir.path(), "vm1", &state);

        // Simulate set_provisioned
        let mut loaded = read_state(dir.path(), "vm1").unwrap();
        loaded.runtime = Some(test_runtime("vm1", "abcd1234", 2222));
        write_state(dir.path(), "vm1", &loaded);

        let result = read_state(dir.path(), "vm1").unwrap();
        assert_eq!(result.target, ".#dev");
        assert_eq!(result.mounts, vec!["/mnt"]);
        let rt = result.runtime.unwrap();
        let BackendState::CloudHypervisor(ch) = &rt.backend else {
            panic!("expected cloud_hypervisor backend state");
        };
        assert_eq!(ch.unit_id, "abcd1234");
        assert_eq!(rt.ssh.port(), 2222);
    }

    #[test]
    fn clear_runtime_preserves_target() {
        let dir = TempDir::new().unwrap();
        let state = InstanceState {
            target: ".#dev".into(),
            runtime: Some(test_runtime("vm1", "abcd", 2222)),
            mounts: vec![],
            project_dir: None,
            disk_size: String::new(),
            cpus: 0,
            memory_mib: 0,
            port_specs: vec![],
            ssh_extra_config: vec![],
            descriptor: None,
        };
        write_state(dir.path(), "vm1", &state);

        // Simulate clear_runtime
        let mut loaded = read_state(dir.path(), "vm1").unwrap();
        loaded.runtime = None;
        write_state(dir.path(), "vm1", &loaded);

        let result = read_state(dir.path(), "vm1").unwrap();
        assert_eq!(result.target, ".#dev");
        assert!(result.runtime.is_none());
    }

    #[test]
    fn set_partial_runtime_writes_unit_id() {
        let dir = TempDir::new().unwrap();
        let state = InstanceState {
            target: ".#dev".into(),
            runtime: None,
            mounts: vec!["/mnt".into()],
            project_dir: None,
            disk_size: String::new(),
            cpus: 0,
            memory_mib: 0,
            port_specs: vec![],
            ssh_extra_config: vec![],
            descriptor: None,
        };
        write_state(dir.path(), "vm1", &state);

        // Simulate set_partial_runtime
        let mut loaded = read_state(dir.path(), "vm1").unwrap();
        loaded.runtime = Some(RunningInstance {
            id: "vm1".into(),
            ssh: SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0),
            serial: SerialEndpoint::UnixSocket {
                path: PathBuf::new(),
            },
            backend: BackendState::CloudHypervisor(ChState {
                unit_id: "abc12345".into(),
            }),
            disk: String::new(),
            ssh_key_path: String::new(),
            ports: vec![],
        });
        write_state(dir.path(), "vm1", &loaded);

        let result = read_state(dir.path(), "vm1").unwrap();
        assert_eq!(result.target, ".#dev");
        assert_eq!(result.mounts, vec!["/mnt"]);
        let rt = result.runtime.unwrap();
        let BackendState::CloudHypervisor(ch) = &rt.backend else {
            panic!("expected cloud_hypervisor backend state");
        };
        assert_eq!(ch.unit_id, "abc12345");
        assert_eq!(rt.ssh.port(), 0);
        match &rt.serial {
            SerialEndpoint::UnixSocket { path } => assert!(path.as_os_str().is_empty()),
            SerialEndpoint::Pty { .. } => panic!("expected unix socket"),
        }
    }

    #[test]
    fn list_from_dir_returns_sorted() {
        let dir = TempDir::new().unwrap();
        let mk = |name: &str, target: &str| {
            write_state(
                dir.path(),
                name,
                &InstanceState {
                    target: target.into(),
                    runtime: None,
                    mounts: vec![],
                    project_dir: None,
                    disk_size: String::new(),
                    cpus: 0,
                    memory_mib: 0,
                    port_specs: vec![],
                    ssh_extra_config: vec![],
                    descriptor: None,
                },
            );
        };
        mk("beta", ".#b");
        mk("alpha", ".#a");
        mk("gamma", ".#g");

        let mut instances = vec![];
        for entry in fs::read_dir(dir.path()).unwrap() {
            let entry = entry.unwrap();
            if entry.file_type().unwrap().is_dir() {
                let name = entry.file_name().to_string_lossy().to_string();
                if let Some(state) = read_state(dir.path(), &name) {
                    instances.push((name, state.target));
                }
            }
        }
        instances.sort_by(|a, b| a.0.cmp(&b.0));

        let names: Vec<&str> = instances.iter().map(|(n, _)| n.as_str()).collect();
        assert_eq!(names, vec!["alpha", "beta", "gamma"]);
    }

    #[test]
    fn remove_deletes_dir() {
        let dir = TempDir::new().unwrap();
        write_state(
            dir.path(),
            "vm1",
            &InstanceState {
                target: ".#dev".into(),
                runtime: None,
                mounts: vec![],
                project_dir: None,
                disk_size: String::new(),
                cpus: 0,
                memory_mib: 0,
                port_specs: vec![],
                ssh_extra_config: vec![],
                descriptor: None,
            },
        );
        assert!(dir.path().join("vm1").exists());

        fs::remove_dir_all(dir.path().join("vm1")).unwrap();
        assert!(!dir.path().join("vm1").exists());
    }

    #[test]
    fn deserialize_missing_optional_fields() {
        let json = r#"{"target": ".#test"}"#;
        let state: InstanceState = serde_json::from_str(json).unwrap();
        assert_eq!(state.target, ".#test");
        assert!(state.runtime.is_none());
        assert!(state.mounts.is_empty());
        assert!(state.project_dir.is_none());
    }

    #[test]
    fn state_with_project_dir_roundtrip() {
        let state = InstanceState {
            target: ".#dev".into(),
            runtime: None,
            mounts: vec![],
            project_dir: Some("/home/user/myproject".into()),
            disk_size: String::new(),
            cpus: 0,
            memory_mib: 0,
            port_specs: vec![],
            ssh_extra_config: vec![],
            descriptor: None,
        };
        let json = serde_json::to_string(&state).unwrap();
        let parsed: InstanceState = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.project_dir.as_deref(), Some("/home/user/myproject"));
    }

    #[test]
    fn state_without_project_dir_deserializes_none() {
        let json = r#"{"target": ".#test", "mounts": []}"#;
        let state: InstanceState = serde_json::from_str(json).unwrap();
        assert!(state.project_dir.is_none());
    }

    #[test]
    fn migrate_legacy_runtime_rewrites_state_json() {
        let dir = TempDir::new().unwrap();
        unsafe { std::env::set_var("EPI_STATE_DIR", dir.path()) };

        // Write a legacy-shape state.json directly (flat CH fields on runtime)
        let name = "legacy";
        let inst_dir = dir.path().join(name);
        fs::create_dir_all(&inst_dir).unwrap();
        let legacy = r#"{
            "target": ".#dev",
            "runtime": {
                "unit_id": "u-old",
                "serial_socket": "/tmp/old/serial.sock",
                "disk": "/tmp/old/disk.img",
                "ssh_port": 2222,
                "ssh_key_path": "/tmp/old/key",
                "ports": [{"host":8080,"guest":80,"protocol":"tcp"}]
            },
            "mounts": [],
            "disk_size": "40G",
            "cpus": 2,
            "memory_mib": 1024,
            "port_specs": [],
            "ssh_extra_config": []
        }"#;
        fs::write(inst_dir.join("state.json"), legacy).unwrap();

        let state = load_state(name).unwrap().unwrap();
        let rt = state.runtime.expect("runtime missing after migration");
        assert_eq!(rt.id, name);
        let BackendState::CloudHypervisor(ch) = &rt.backend else {
            panic!("expected cloud_hypervisor backend state");
        };
        assert_eq!(ch.unit_id, "u-old");
        assert_eq!(rt.ssh.port(), 2222);
        assert_eq!(rt.disk, "/tmp/old/disk.img");
        assert_eq!(rt.ssh_key_path, "/tmp/old/key");
        assert_eq!(rt.ports.len(), 1);
        match &rt.serial {
            SerialEndpoint::UnixSocket { path } => {
                assert_eq!(path.to_string_lossy(), "/tmp/old/serial.sock");
            }
            SerialEndpoint::Pty { .. } => panic!("expected unix socket"),
        }

        // Verify the file was rewritten in the new tagged shape
        let rewritten = fs::read_to_string(inst_dir.join("state.json")).unwrap();
        assert!(rewritten.contains(r#""kind": "cloud_hypervisor""#));
        assert!(rewritten.contains(r#""kind": "unix_socket""#));
        assert!(!rewritten.contains(r#""unit_id": "u-old","#)); // not at top level any more
        // Second load is a no-op (already migrated)
        let _ = load_state(name).unwrap();

        unsafe { std::env::remove_var("EPI_STATE_DIR") };
    }

    #[test]
    fn deserialize_missing_new_vm_param_fields() {
        // epi-a93: existing state.json without cpus, memory_mib, port_specs should deserialize
        let json = r#"{"target": ".#test", "mounts": [], "disk_size": "40G"}"#;
        let state: InstanceState = serde_json::from_str(json).unwrap();
        assert_eq!(state.target, ".#test");
        assert_eq!(state.cpus, 1);
        assert_eq!(state.memory_mib, 1024);
        assert!(state.port_specs.is_empty());
    }

    #[test]
    fn state_with_cpus_and_memory_roundtrip() {
        // epi-zeq: cpus and memory_mib persist in state
        let state = InstanceState {
            target: ".#dev".into(),
            runtime: None,
            mounts: vec![],
            project_dir: None,
            disk_size: "40G".into(),
            cpus: 4,
            memory_mib: 2048,
            port_specs: vec![],
            ssh_extra_config: vec![],
            descriptor: None,
        };
        let json = serde_json::to_string(&state).unwrap();
        let parsed: InstanceState = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.cpus, 4);
        assert_eq!(parsed.memory_mib, 2048);
    }

    #[test]
    fn state_with_port_specs_roundtrip() {
        // epi-ch5: port_specs persist in state
        let state = InstanceState {
            target: ".#dev".into(),
            runtime: None,
            mounts: vec![],
            project_dir: None,
            disk_size: String::new(),
            cpus: 0,
            memory_mib: 0,
            port_specs: vec!["8080:80".into(), ":443".into()],
            ssh_extra_config: vec![],
            descriptor: None,
        };
        let json = serde_json::to_string(&state).unwrap();
        let parsed: InstanceState = serde_json::from_str(&json).unwrap();
        assert_eq!(
            parsed.port_specs,
            vec!["8080:80".to_string(), ":443".to_string()]
        );
    }

    #[test]
    fn parse_port_mapping_host_and_guest() {
        let (host, guest) = parse_port_mapping("8080:80").unwrap();
        assert_eq!(host, 8080);
        assert_eq!(guest, 80);
    }

    #[test]
    fn parse_port_mapping_auto_host() {
        let (host, guest) = parse_port_mapping(":443").unwrap();
        assert_eq!(host, 0);
        assert_eq!(guest, 443);
    }

    #[test]
    fn parse_port_mapping_invalid_no_colon() {
        assert!(parse_port_mapping("8080").is_err());
    }

    #[test]
    fn parse_port_mapping_invalid_guest() {
        assert!(parse_port_mapping(":abc").is_err());
    }

    #[test]
    fn parse_port_mapping_invalid_host() {
        assert!(parse_port_mapping("abc:80").is_err());
    }

    #[test]
    fn port_mapping_serialization_roundtrip() {
        let pm = PortMapping {
            host: 8080,
            guest: 80,
            protocol: "tcp".into(),
        };
        let json = serde_json::to_string(&pm).unwrap();
        let parsed: PortMapping = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed, pm);
    }

    #[test]
    fn runtime_with_ports_roundtrip() {
        let mut rt = test_runtime("vm1", "abc", 2222);
        rt.ports = vec![
            PortMapping {
                host: 8080,
                guest: 80,
                protocol: "tcp".into(),
            },
            PortMapping {
                host: 4443,
                guest: 443,
                protocol: "tcp".into(),
            },
        ];
        let json = serde_json::to_string(&rt).unwrap();
        let parsed: RunningInstance = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.ports.len(), 2);
        assert_eq!(parsed.ports[0].host, 8080);
        assert_eq!(parsed.ports[1].guest, 443);
    }

    #[test]
    fn runtime_without_ports_deserializes_empty() {
        // New-shape state.json without "ports" field on runtime should still deserialize
        let json = r#"{
            "id": "vm1",
            "ssh": "127.0.0.1:2222",
            "serial": {"kind":"unix_socket","path":"/s"},
            "backend": {"kind":"cloud_hypervisor","unit_id":"abc"},
            "disk": "/d",
            "ssh_key_path": "/k"
        }"#;
        let parsed: RunningInstance = serde_json::from_str(json).unwrap();
        assert!(parsed.ports.is_empty());
    }

    #[test]
    fn state_with_descriptor_roundtrip() {
        use crate::target::{Descriptor, HooksDescriptor};
        use std::collections::BTreeMap;

        let mut post_launch = BTreeMap::new();
        post_launch.insert("00-hook".into(), "/nix/store/hook1/script".into());

        let desc = Descriptor {
            kernel: "/nix/store/abc-kernel/bzImage".into(),
            disk: "/nix/store/def-image/image.img".into(),
            disk_qcow2: None,
            initrd: Some("/nix/store/ghi-initrd/initrd".into()),
            cmdline: "console=ttyS0 root=/dev/vda2 ro".into(),
            configured_users: vec!["root".into()],
            hooks: HooksDescriptor {
                post_launch,
                pre_stop: BTreeMap::new(),
                guest_init: BTreeMap::new(),
            },
        };

        let state = InstanceState {
            target: ".#dev".into(),
            runtime: None,
            mounts: vec![],
            project_dir: None,
            disk_size: String::new(),
            cpus: 0,
            memory_mib: 0,
            port_specs: vec![],
            ssh_extra_config: vec![],
            descriptor: Some(desc),
        };
        let json = serde_json::to_string(&state).unwrap();
        let parsed: InstanceState = serde_json::from_str(&json).unwrap();
        let d = parsed.descriptor.unwrap();
        assert_eq!(d.kernel, "/nix/store/abc-kernel/bzImage");
        assert_eq!(d.disk, "/nix/store/def-image/image.img");
        assert_eq!(d.initrd.unwrap(), "/nix/store/ghi-initrd/initrd");
        assert_eq!(d.hooks.post_launch.len(), 1);
    }

    #[test]
    fn state_without_descriptor_deserializes_none() {
        let json = r#"{"target": ".#test", "mounts": []}"#;
        let state: InstanceState = serde_json::from_str(json).unwrap();
        assert!(state.descriptor.is_none());
    }

    #[test]
    fn list_sorts_projects_before_global() {
        let dir = TempDir::new().unwrap();
        let mk = |name: &str, target: &str, project: Option<&str>| {
            write_state(
                dir.path(),
                name,
                &InstanceState {
                    target: target.into(),
                    runtime: None,
                    mounts: vec![],
                    project_dir: project.map(|s| s.to_string()),
                    disk_size: String::new(),
                    cpus: 0,
                    memory_mib: 0,
                    port_specs: vec![],
                    ssh_extra_config: vec![],
                    descriptor: None,
                },
            );
        };
        mk("global-b", ".#b", None);
        mk("proj-a", ".#a", Some("/home/user/proj"));
        mk("global-a", ".#a", None);
        mk("proj-b", ".#b", Some("/home/user/proj"));

        // Simulate the sort logic from list()
        let mut instances: Vec<(String, String, Option<String>)> = vec![];
        for entry in fs::read_dir(dir.path()).unwrap() {
            let entry = entry.unwrap();
            if entry.file_type().unwrap().is_dir() {
                let name = entry.file_name().to_string_lossy().to_string();
                if let Some(state) = read_state(dir.path(), &name) {
                    instances.push((name, state.target, state.project_dir));
                }
            }
        }
        instances.sort_by(|a, b| {
            let a_has_project = a.2.is_some();
            let b_has_project = b.2.is_some();
            b_has_project.cmp(&a_has_project).then(a.0.cmp(&b.0))
        });

        let names: Vec<&str> = instances.iter().map(|(n, _, _)| n.as_str()).collect();
        assert_eq!(names, vec!["proj-a", "proj-b", "global-a", "global-b"]);
    }

    #[test]
    fn state_dir_returns_absolute_path() {
        let dir = state_dir();
        assert!(
            dir.is_absolute(),
            "state_dir() returned relative path: {dir:?}"
        );
    }
}
