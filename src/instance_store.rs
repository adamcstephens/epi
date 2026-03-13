use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;

use crate::process;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Runtime {
    pub unit_id: String,
    pub serial_socket: String,
    pub disk: String,
    pub ssh_port: Option<u16>,
    pub ssh_key_path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InstanceState {
    pub target: String,
    #[serde(default)]
    pub runtime: Option<Runtime>,
    #[serde(default)]
    pub mounts: Vec<String>,
}

pub fn state_dir() -> PathBuf {
    if let Ok(dir) = std::env::var("EPI_STATE_DIR") {
        return PathBuf::from(dir);
    }
    if let Ok(home) = std::env::var("HOME") {
        return PathBuf::from(home).join(".local/state/epi");
    }
    PathBuf::from(".epi-state")
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

pub fn save_target(name: &str, target: &str) -> Result<()> {
    let state = InstanceState {
        target: target.to_string(),
        runtime: None,
        mounts: vec![],
    };
    save_state(name, &state)
}

pub fn set_launching(name: &str, target: &str, mounts: Vec<String>) -> Result<()> {
    let canonical_mounts: Vec<String> = mounts
        .iter()
        .map(|m| {
            std::path::Path::new(m)
                .canonicalize()
                .map(|p| p.to_string_lossy().to_string())
                .unwrap_or_else(|_| m.clone())
        })
        .collect();
    let state = InstanceState {
        target: target.to_string(),
        runtime: None,
        mounts: canonical_mounts,
    };
    save_state(name, &state)
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
    });
    save_state(name, &state)
}

pub fn set_provisioned(name: &str, runtime: Runtime) -> Result<()> {
    let mut state =
        load_state(name)?.ok_or_else(|| anyhow::anyhow!("instance {name} does not exist"))?;
    state.runtime = Some(runtime);
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

pub fn list() -> Result<Vec<(String, String)>> {
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
                instances.push((name, state.target));
            }
        }
    }
    instances.sort_by(|a, b| a.0.cmp(&b.0));
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

pub fn vm_unit_name(name: &str, unit_id: &str) -> Result<String> {
    let escaped = process::escape_unit_name(name)?;
    Ok(format!("epi-{escaped}_{unit_id}_vm.service"))
}

pub fn slice_name(name: &str, unit_id: &str) -> Result<String> {
    let escaped = process::escape_unit_name(name)?;
    Ok(format!("epi-{escaped}_{unit_id}.slice"))
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
            }),
            mounts: vec!["/a".into(), "/b".into()],
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
            }),
            mounts: vec![],
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
    }

    #[test]
    fn runtime_ssh_port_optional() {
        let rt = Runtime {
            unit_id: "abc".into(),
            serial_socket: "/s".into(),
            disk: "/d".into(),
            ssh_port: None,
            ssh_key_path: "/k".into(),
        };
        let json = serde_json::to_string(&rt).unwrap();
        let parsed: Runtime = serde_json::from_str(&json).unwrap();
        assert!(parsed.ssh_port.is_none());
    }
}
