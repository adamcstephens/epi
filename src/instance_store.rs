use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;

use crate::process;
use crate::target;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PortMapping {
    pub host: u16,
    pub guest: u16,
    pub protocol: String,
}

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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Runtime {
    pub unit_id: String,
    pub serial_socket: String,
    pub disk: String,
    pub ssh_port: Option<u16>,
    pub ssh_key_path: String,
    #[serde(default)]
    pub ports: Vec<PortMapping>,
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
    pub runtime: Option<Runtime>,
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
    let state: InstanceState =
        serde_json::from_str(&content).with_context(|| format!("parsing {}", path.display()))?;
    Ok(Some(state))
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
    state.runtime = Some(Runtime {
        unit_id: unit_id.to_string(),
        serial_socket: String::new(),
        disk: String::new(),
        ssh_port: None,
        ssh_key_path: String::new(),
        ports: vec![],
    });
    save_state(name, &state)
}

pub fn set_provisioned(
    name: &str,
    runtime: Runtime,
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

pub fn find_runtime(name: &str) -> Result<Option<Runtime>> {
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

/// Build a systemd unit name with the instance name escaped.
/// All epi unit names go through this to ensure consistent escaping.
///
/// - `suffix` = "" → slice:   `epi-{escaped}_{unit_id}.slice`
/// - `suffix` = "vm" → service: `epi-{escaped}_{unit_id}_vm.service`
/// - `suffix` = "passt" → service: `epi-{escaped}_{unit_id}_passt.service`
/// - `suffix` = "virtiofsd0" → service: `epi-{escaped}_{unit_id}_virtiofsd0.service`
pub fn unit_name(name: &str, unit_id: &str, suffix: &str) -> Result<String> {
    let escaped = process::escape_unit_name(name)?;
    if suffix.is_empty() {
        Ok(format!("epi-{escaped}_{unit_id}.slice"))
    } else {
        Ok(format!("epi-{escaped}_{unit_id}_{suffix}.service"))
    }
}

pub fn vm_unit_name(name: &str, unit_id: &str) -> Result<String> {
    unit_name(name, unit_id, "vm")
}

pub fn slice_name(name: &str, unit_id: &str) -> Result<String> {
    unit_name(name, unit_id, "")
}

pub fn passt_unit_name(name: &str, unit_id: &str) -> Result<String> {
    unit_name(name, unit_id, "passt")
}

pub fn virtiofsd_unit_name(name: &str, unit_id: &str, index: usize) -> Result<String> {
    unit_name(name, unit_id, &format!("virtiofsd{index}"))
}

pub fn instance_is_running(name: &str) -> Result<bool> {
    let runtime = match find_runtime(name)? {
        Some(r) => r,
        None => return Ok(false),
    };
    let unit = vm_unit_name(name, &runtime.unit_id)?;
    process::unit_is_active(&unit)
}

pub fn find_running_owner_by_disk(disk: &str) -> Result<Option<(String, String)>> {
    let dir = state_dir();
    if !dir.exists() {
        return Ok(None);
    }
    for entry in fs::read_dir(&dir)? {
        let entry = entry?;
        if entry.file_type()?.is_dir() {
            let name = entry.file_name().to_string_lossy().to_string();
            if let Some(state) = load_state(&name)?
                && let Some(ref rt) = state.runtime
                && rt.disk == disk
            {
                let unit = vm_unit_name(&name, &rt.unit_id)?;
                if process::unit_is_active(&unit)? {
                    return Ok(Some((name, rt.unit_id.clone())));
                }
            }
        }
    }
    Ok(None)
}

pub fn console_log_path(name: &str) -> PathBuf {
    instance_path(name, "console.log")
}

#[cfg(test)]
mod tests {
    use super::*;
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

    #[test]
    fn state_json_roundtrip() {
        let state = InstanceState {
            target: ".#test".into(),
            runtime: Some(Runtime {
                unit_id: "aabb".into(),
                serial_socket: "/s".into(),
                disk: "/d".into(),
                ssh_port: Some(3333),
                ssh_key_path: "/k".into(),
                ports: vec![],
            }),
            mounts: vec!["/a".into(), "/b".into()],
            project_dir: None,
            disk_size: String::new(),
            cpus: 0,
            memory_mib: 0,
            port_specs: vec![],
            descriptor: None,
        };
        let json = serde_json::to_string(&state).unwrap();
        let parsed: InstanceState = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.target, ".#test");
        assert_eq!(parsed.runtime.unwrap().ssh_port, Some(3333));
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
            descriptor: None,
        };
        write_state(dir.path(), "vm1", &state);

        // Simulate set_provisioned
        let mut loaded = read_state(dir.path(), "vm1").unwrap();
        loaded.runtime = Some(Runtime {
            unit_id: "abcd1234".into(),
            serial_socket: "/tmp/serial.sock".into(),
            disk: "/tmp/disk.img".into(),
            ssh_port: Some(2222),
            ssh_key_path: "/tmp/id_ed25519".into(),
            ports: vec![],
        });
        write_state(dir.path(), "vm1", &loaded);

        let result = read_state(dir.path(), "vm1").unwrap();
        assert_eq!(result.target, ".#dev");
        assert_eq!(result.mounts, vec!["/mnt"]);
        let rt = result.runtime.unwrap();
        assert_eq!(rt.unit_id, "abcd1234");
        assert_eq!(rt.ssh_port, Some(2222));
    }

    #[test]
    fn clear_runtime_preserves_target() {
        let dir = TempDir::new().unwrap();
        let state = InstanceState {
            target: ".#dev".into(),
            runtime: Some(Runtime {
                unit_id: "abcd".into(),
                serial_socket: "".into(),
                disk: "".into(),
                ssh_port: Some(2222),
                ssh_key_path: "".into(),
                ports: vec![],
            }),
            mounts: vec![],
            project_dir: None,
            disk_size: String::new(),
            cpus: 0,
            memory_mib: 0,
            port_specs: vec![],
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
            descriptor: None,
        };
        write_state(dir.path(), "vm1", &state);

        // Simulate set_partial_runtime
        let mut loaded = read_state(dir.path(), "vm1").unwrap();
        loaded.runtime = Some(Runtime {
            unit_id: "abc12345".into(),
            serial_socket: String::new(),
            disk: String::new(),
            ssh_port: None,
            ssh_key_path: String::new(),
            ports: vec![],
        });
        write_state(dir.path(), "vm1", &loaded);

        let result = read_state(dir.path(), "vm1").unwrap();
        assert_eq!(result.target, ".#dev");
        assert_eq!(result.mounts, vec!["/mnt"]);
        let rt = result.runtime.unwrap();
        assert_eq!(rt.unit_id, "abc12345");
        assert!(rt.ssh_port.is_none());
        assert!(rt.serial_socket.is_empty());
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
    fn runtime_ssh_port_optional() {
        let rt = Runtime {
            unit_id: "abc".into(),
            serial_socket: "/s".into(),
            disk: "/d".into(),
            ssh_port: None,
            ssh_key_path: "/k".into(),
            ports: vec![],
        };
        let json = serde_json::to_string(&rt).unwrap();
        let parsed: Runtime = serde_json::from_str(&json).unwrap();
        assert!(parsed.ssh_port.is_none());
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
        let rt = Runtime {
            unit_id: "abc".into(),
            serial_socket: "/s".into(),
            disk: "/d".into(),
            ssh_port: Some(2222),
            ssh_key_path: "/k".into(),
            ports: vec![
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
            ],
        };
        let json = serde_json::to_string(&rt).unwrap();
        let parsed: Runtime = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.ports.len(), 2);
        assert_eq!(parsed.ports[0].host, 8080);
        assert_eq!(parsed.ports[1].guest, 443);
    }

    #[test]
    fn runtime_without_ports_deserializes_empty() {
        // Old state.json without "ports" field should still deserialize
        let json = r#"{"unit_id":"abc","serial_socket":"/s","disk":"/d","ssh_port":2222,"ssh_key_path":"/k"}"#;
        let parsed: Runtime = serde_json::from_str(json).unwrap();
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
    fn unit_name_slice() {
        let name = unit_name("simple", "abc", "").unwrap();
        assert_eq!(name, "epi-simple_abc.slice");
    }

    #[test]
    fn unit_name_vm() {
        let name = vm_unit_name("simple", "abc").unwrap();
        assert_eq!(name, "epi-simple_abc_vm.service");
    }

    #[test]
    fn unit_name_passt() {
        let name = passt_unit_name("simple", "abc").unwrap();
        assert_eq!(name, "epi-simple_abc_passt.service");
    }

    #[test]
    fn unit_name_virtiofsd() {
        let name = virtiofsd_unit_name("simple", "abc", 0).unwrap();
        assert_eq!(name, "epi-simple_abc_virtiofsd0.service");
        let name = virtiofsd_unit_name("simple", "abc", 2).unwrap();
        assert_eq!(name, "epi-simple_abc_virtiofsd2.service");
    }

    #[test]
    fn unit_name_escapes_instance_name() {
        // epi-dev contains a dash which systemd escapes
        let name = unit_name("epi-dev", "abc", "vm").unwrap();
        assert!(
            name.contains("\\x2d"),
            "should contain escaped dash: {name}"
        );
        assert!(name.ends_with("_vm.service"));
    }

    #[test]
    fn unit_name_all_variants_consistent() {
        // All unit name functions should produce names with the same escaped prefix
        let slice = slice_name("epi-dev", "abc").unwrap();
        let vm = vm_unit_name("epi-dev", "abc").unwrap();
        let passt = passt_unit_name("epi-dev", "abc").unwrap();
        let vfsd = virtiofsd_unit_name("epi-dev", "abc", 0).unwrap();

        // Extract the common prefix (everything before the suffix)
        let prefix = "epi-epi\\x2ddev_abc";
        assert!(slice.starts_with(prefix), "slice: {slice}");
        assert!(vm.starts_with(prefix), "vm: {vm}");
        assert!(passt.starts_with(prefix), "passt: {passt}");
        assert!(vfsd.starts_with(prefix), "vfsd: {vfsd}");
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
