use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use crate::process;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct HooksDescriptor {
    #[serde(default, alias = "post-launch")]
    pub post_launch: BTreeMap<String, String>,
    #[serde(default, alias = "pre-stop")]
    pub pre_stop: BTreeMap<String, String>,
    #[serde(default, alias = "guest-init")]
    pub guest_init: BTreeMap<String, String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Descriptor {
    pub kernel: String,
    pub disk: String,
    #[serde(default)]
    pub initrd: Option<String>,
    #[serde(default = "default_cmdline")]
    pub cmdline: String,
    #[serde(default = "default_cpus")]
    pub cpus: u32,
    #[serde(default = "default_memory_mib")]
    pub memory_mib: u32,
    #[serde(default, alias = "configuredUsers")]
    pub configured_users: Vec<String>,
    #[serde(default)]
    pub hooks: HooksDescriptor,
}

fn default_cmdline() -> String {
    "console=ttyS0 root=/dev/vda2 ro".to_string()
}

fn default_cpus() -> u32 {
    1
}

fn default_memory_mib() -> u32 {
    1024
}

impl HooksDescriptor {
    /// Sorted hook script paths for a given hook point.
    pub fn post_launch_scripts(&self) -> Vec<String> {
        self.post_launch.values().cloned().collect()
    }

    pub fn pre_stop_scripts(&self) -> Vec<String> {
        self.pre_stop.values().cloned().collect()
    }

    pub fn guest_init_scripts(&self) -> Vec<String> {
        self.guest_init.values().cloned().collect()
    }
}

/// Expand tilde in the flake-ref portion of a target string
pub fn expand_tilde(target: &str) -> String {
    if let Some((flake, config)) = target.split_once('#') {
        if let Some(rest) = flake.strip_prefix("~/")
            && let Ok(home) = std::env::var("HOME")
        {
            return format!("{home}/{rest}#{config}");
        }
        if flake == "~"
            && let Ok(home) = std::env::var("HOME")
        {
            return format!("{home}#{config}");
        }
    }
    target.to_string()
}

/// Validate target format: must contain '#'
pub fn validate(target: &str) -> Result<()> {
    let parts: Vec<&str> = target.splitn(2, '#').collect();
    if parts.len() != 2 || parts[0].is_empty() || parts[1].is_empty() {
        bail!("invalid target format: expected <flake-ref>#<config-name>, got: {target}");
    }
    Ok(())
}

/// Canonicalize target by adding nixosConfigurations. prefix if needed
pub fn canonicalize(target: &str) -> String {
    if let Some((flake, config)) = target.split_once('#')
        && !config.starts_with("nixosConfigurations.")
    {
        return format!("{flake}#nixosConfigurations.{config}");
    }
    target.to_string()
}

/// Resolve a flake target to a descriptor by evaluating nix
pub fn resolve_descriptor(target: &str) -> Result<Descriptor> {
    if let Ok(resolver) = std::env::var("EPI_TARGET_RESOLVER_CMD") {
        let out = process::run_with_env(&resolver, &[], &[("EPI_TARGET", target)])?;
        if !out.success() {
            bail!(
                "target resolver {resolver} failed (exit {}): {}",
                out.status,
                out.stderr
            );
        }
        let desc: Descriptor = serde_json::from_str(&out.stdout)
            .context("failed to parse resolver output as descriptor")?;
        return Ok(desc);
    }

    let canonical = canonicalize(target);

    // Check target exists
    let check = process::run("nix", &["eval", &canonical, "--apply", "x: true"])?;
    if !check.success() {
        bail!(
            "target resolution failed for {target} (exit {}): {}",
            check.status,
            check.stderr
        );
    }

    // Evaluate config
    let epi_attr = format!("{canonical}.config.epi");
    let eval = process::run("nix", &["eval", "--json", &epi_attr])?;
    if !eval.success() {
        bail!(
            "failed to evaluate {epi_attr} (exit {}): {}",
            eval.status,
            eval.stderr
        );
    }

    let desc: Descriptor =
        serde_json::from_str(&eval.stdout).context("failed to parse descriptor from nix eval")?;
    Ok(desc)
}

pub fn is_nix_store_path(path: &str) -> bool {
    path.starts_with("/nix/store/")
}

/// Ensure all nix store paths from the descriptor are built.
/// If any are missing, builds the flake target to produce them.
pub fn ensure_paths_exist(target: &str, desc: &Descriptor) -> Result<()> {
    let paths = descriptor_store_paths(desc);
    let any_missing = paths.iter().any(|p| !Path::new(p).exists());

    if any_missing {
        let canonical = canonicalize(target);
        let toplevel = format!("{canonical}.config.system.build.toplevel");
        let image = format!("{canonical}.config.system.build.image");
        let out = process::run("nix", &["build", &toplevel, &image, "--no-link"])?;
        if !out.success() {
            bail!("nix build failed (exit {}): {}", out.status, out.stderr);
        }
    }

    for path in &paths {
        if !Path::new(path).exists() {
            bail!("path does not exist after build: {path}");
        }
    }
    Ok(())
}

pub fn validate_descriptor(desc: &Descriptor) -> Result<()> {
    if desc.cpus == 0 {
        bail!("descriptor cpus must be > 0");
    }
    if desc.memory_mib == 0 {
        bail!("descriptor memory_mib must be > 0");
    }
    Ok(())
}

fn descriptor_store_paths(desc: &Descriptor) -> Vec<&str> {
    let mut paths = vec![desc.kernel.as_str(), desc.disk.as_str()];
    if let Some(ref initrd) = desc.initrd {
        paths.push(initrd.as_str());
    }
    for script in desc.hooks.post_launch.values() {
        if is_nix_store_path(script) {
            paths.push(script.as_str());
        }
    }
    for script in desc.hooks.pre_stop.values() {
        if is_nix_store_path(script) {
            paths.push(script.as_str());
        }
    }
    for script in desc.hooks.guest_init.values() {
        if is_nix_store_path(script) {
            paths.push(script.as_str());
        }
    }
    paths
}

// --- Caching ---

fn cache_dir() -> PathBuf {
    if let Ok(dir) = std::env::var("EPI_CACHE_DIR") {
        return PathBuf::from(dir);
    }
    if let Ok(home) = std::env::var("HOME") {
        return PathBuf::from(home).join(".cache/epi");
    }
    PathBuf::from(".epi/cache")
}

fn target_cache_path(target: &str) -> PathBuf {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    let mut hasher = DefaultHasher::new();
    target.hash(&mut hasher);
    let hash = hasher.finish();
    cache_dir()
        .join("targets")
        .join(format!("{hash:016x}.descriptor"))
}

pub enum CacheResult {
    Cached(Descriptor),
    Resolved(Descriptor),
}

impl CacheResult {
    pub fn descriptor(&self) -> &Descriptor {
        match self {
            CacheResult::Cached(d) | CacheResult::Resolved(d) => d,
        }
    }
}

/// Deserialize a descriptor from JSON (useful for testing and resolver output)
pub fn descriptor_from_json(json: &str) -> Result<Descriptor> {
    serde_json::from_str(json).context("failed to parse descriptor JSON")
}

pub fn resolve_descriptor_cached(target: &str, rebuild: bool) -> Result<CacheResult> {
    let cache_path = target_cache_path(target);

    if rebuild {
        let _ = fs::remove_file(&cache_path);
    }

    // Try loading from cache
    if let Ok(content) = fs::read_to_string(&cache_path)
        && let Ok(desc) = serde_json::from_str::<Descriptor>(&content)
    {
        // Verify cached paths still exist
        let paths_exist = descriptor_store_paths(&desc)
            .iter()
            .all(|p| Path::new(p).exists());
        if paths_exist {
            return Ok(CacheResult::Cached(desc));
        }
    }

    // Resolve fresh
    let desc = resolve_descriptor(target)?;

    // Cache it
    if let Some(parent) = cache_path.parent() {
        fs::create_dir_all(parent)?;
    }
    let content = serde_json::to_string_pretty(&desc)?;
    fs::write(&cache_path, content)?;

    Ok(CacheResult::Resolved(desc))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validate_accepts_valid_target() {
        assert!(validate(".#myconfig").is_ok());
        assert!(validate("github:user/repo#config").is_ok());
    }

    #[test]
    fn validate_rejects_missing_hash() {
        assert!(validate("nohash").is_err());
    }

    #[test]
    fn validate_rejects_empty_parts() {
        assert!(validate("#config").is_err());
        assert!(validate("flake#").is_err());
        assert!(validate("#").is_err());
    }

    #[test]
    fn canonicalize_adds_prefix() {
        assert_eq!(canonicalize(".#dev"), ".#nixosConfigurations.dev");
    }

    #[test]
    fn canonicalize_preserves_existing_prefix() {
        assert_eq!(
            canonicalize(".#nixosConfigurations.dev"),
            ".#nixosConfigurations.dev"
        );
    }

    #[test]
    fn canonicalize_handles_full_flake_ref() {
        assert_eq!(
            canonicalize("github:user/repo#myvm"),
            "github:user/repo#nixosConfigurations.myvm"
        );
    }

    #[test]
    fn is_nix_store_path_works() {
        assert!(is_nix_store_path("/nix/store/abc-thing/bzImage"));
        assert!(!is_nix_store_path("/home/user/disk.img"));
    }

    #[test]
    fn validate_descriptor_rejects_zero_cpus() {
        let desc = Descriptor {
            kernel: "/k".into(),
            disk: "/d".into(),
            initrd: None,
            cmdline: "".into(),
            cpus: 0,
            memory_mib: 512,
            configured_users: vec![],
            hooks: HooksDescriptor::default(),
        };
        assert!(validate_descriptor(&desc).is_err());
    }

    #[test]
    fn validate_descriptor_rejects_zero_memory() {
        let desc = Descriptor {
            kernel: "/k".into(),
            disk: "/d".into(),
            initrd: None,
            cmdline: "".into(),
            cpus: 2,
            memory_mib: 0,
            configured_users: vec![],
            hooks: HooksDescriptor::default(),
        };
        assert!(validate_descriptor(&desc).is_err());
    }

    #[test]
    fn validate_descriptor_accepts_valid() {
        let desc = Descriptor {
            kernel: "/k".into(),
            disk: "/d".into(),
            initrd: None,
            cmdline: "".into(),
            cpus: 2,
            memory_mib: 1024,
            configured_users: vec![],
            hooks: HooksDescriptor::default(),
        };
        assert!(validate_descriptor(&desc).is_ok());
    }

    #[test]
    fn descriptor_deserialize_defaults() {
        let json = r#"{"kernel": "/k", "disk": "/d"}"#;
        let desc: Descriptor = serde_json::from_str(json).unwrap();
        assert_eq!(desc.cpus, 1);
        assert_eq!(desc.memory_mib, 1024);
        assert_eq!(desc.cmdline, "console=ttyS0 root=/dev/vda2 ro");
        assert!(desc.initrd.is_none());
        assert!(desc.configured_users.is_empty());
    }

    #[test]
    fn descriptor_deserialize_full() {
        let json = r#"{
            "kernel": "/nix/store/abc/bzImage",
            "disk": "/nix/store/abc/image.img",
            "initrd": "/nix/store/abc/initrd",
            "cmdline": "console=ttyS0",
            "cpus": 4,
            "memory_mib": 2048,
            "configured_users": ["root", "admin"],
            "hooks": {
                "post_launch": {"00-hook": "/nix/store/hook1"},
                "pre_stop": {}
            }
        }"#;
        let desc: Descriptor = serde_json::from_str(json).unwrap();
        assert_eq!(desc.cpus, 4);
        assert_eq!(desc.memory_mib, 2048);
        assert_eq!(desc.initrd.unwrap(), "/nix/store/abc/initrd");
        assert_eq!(desc.configured_users.len(), 2);
        assert_eq!(desc.hooks.post_launch.len(), 1);
    }

    #[test]
    fn descriptor_deserialize_camel_case_aliases() {
        let json = r#"{
            "kernel": "/k",
            "disk": "/d",
            "configuredUsers": ["root", "admin"],
            "hooks": {
                "post-launch": {"00-hook1": "/nix/store/hook1"},
                "pre-stop": {"00-hook2": "/nix/store/hook2"}
            }
        }"#;
        let desc: Descriptor = serde_json::from_str(json).unwrap();
        assert_eq!(desc.configured_users, vec!["root", "admin"]);
        assert_eq!(desc.hooks.post_launch_scripts(), vec!["/nix/store/hook1"]);
        assert_eq!(desc.hooks.pre_stop_scripts(), vec!["/nix/store/hook2"]);
    }

    #[test]
    fn expand_tilde_in_target() {
        let home = std::env::var("HOME").unwrap();
        assert_eq!(expand_tilde("~/repo#config"), format!("{home}/repo#config"));
        assert_eq!(expand_tilde("~#config"), format!("{home}#config"));
        assert_eq!(expand_tilde(".#config"), ".#config");
        assert_eq!(expand_tilde("/abs/path#config"), "/abs/path#config");
    }

    #[test]
    fn descriptor_roundtrip_json() {
        let desc = Descriptor {
            kernel: "/k".into(),
            disk: "/d".into(),
            initrd: Some("/i".into()),
            cmdline: "boot".into(),
            cpus: 2,
            memory_mib: 1024,
            configured_users: vec!["root".into()],
            hooks: HooksDescriptor::default(),
        };
        let json = serde_json::to_string(&desc).unwrap();
        let parsed: Descriptor = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.kernel, desc.kernel);
        assert_eq!(parsed.cpus, desc.cpus);
    }
}
