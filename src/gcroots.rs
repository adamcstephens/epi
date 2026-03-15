use anyhow::{Context, Result, bail};
use std::fs;
use std::path::PathBuf;

use crate::instance_store;
use crate::process;
use crate::target::{self, Descriptor};

/// Directory within the instance state dir where GC root symlinks live.
fn gcroots_dir(instance: &str) -> PathBuf {
    instance_store::instance_dir(instance).join("gcroots")
}

/// Collect all nix store paths from a descriptor that need GC roots.
/// Returns (label, store_path) pairs.
fn store_paths_to_root(desc: &Descriptor) -> Vec<(String, &str)> {
    let mut paths = Vec::new();

    paths.push(("kernel".to_string(), desc.kernel.as_str()));
    paths.push(("disk".to_string(), desc.disk.as_str()));

    if let Some(ref initrd) = desc.initrd {
        paths.push(("initrd".to_string(), initrd.as_str()));
    }

    for (name, script) in &desc.hooks.post_launch {
        if target::is_nix_store_path(script) {
            paths.push((format!("hook-post-launch-{name}"), script.as_str()));
        }
    }
    for (name, script) in &desc.hooks.pre_stop {
        if target::is_nix_store_path(script) {
            paths.push((format!("hook-pre-stop-{name}"), script.as_str()));
        }
    }
    for (name, script) in &desc.hooks.guest_init {
        if target::is_nix_store_path(script) {
            paths.push((format!("hook-guest-init-{name}"), script.as_str()));
        }
    }

    paths
}

/// Create GC roots for all nix store paths referenced by the descriptor.
///
/// Each root is a symlink in `.epi/state/<instance>/gcroots/<label>` registered
/// via `nix-store --add-root --realise`.
pub fn create(instance: &str, desc: &Descriptor) -> Result<()> {
    let dir = gcroots_dir(instance);
    fs::create_dir_all(&dir).with_context(|| format!("creating gcroots dir: {}", dir.display()))?;

    let paths = store_paths_to_root(desc);
    for (label, store_path) in &paths {
        let link = dir.join(label);
        let link_str = link.to_string_lossy();
        let out = process::run(
            "nix-store",
            &["--add-root", &link_str, "--realise", store_path],
        )?;
        if !out.success() {
            bail!(
                "nix-store --add-root failed for {label} (exit {}): {}",
                out.status,
                out.stderr
            );
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::target::HooksDescriptor;
    use std::collections::BTreeMap;

    #[test]
    fn store_paths_to_root_kernel_and_disk() {
        let desc = Descriptor {
            kernel: "/nix/store/abc-kernel/bzImage".into(),
            disk: "/nix/store/def-image/image.img".into(),
            initrd: None,
            cmdline: String::new(),
            configured_users: vec![],
            hooks: HooksDescriptor::default(),
        };

        let paths = store_paths_to_root(&desc);
        assert_eq!(paths.len(), 2);
        assert_eq!(
            paths[0],
            ("kernel".to_string(), "/nix/store/abc-kernel/bzImage")
        );
        assert_eq!(
            paths[1],
            ("disk".to_string(), "/nix/store/def-image/image.img")
        );
    }

    #[test]
    fn store_paths_to_root_with_initrd() {
        let desc = Descriptor {
            kernel: "/nix/store/abc-kernel/bzImage".into(),
            disk: "/nix/store/def-image/image.img".into(),
            initrd: Some("/nix/store/ghi-initrd/initrd".into()),
            cmdline: String::new(),
            configured_users: vec![],
            hooks: HooksDescriptor::default(),
        };

        let paths = store_paths_to_root(&desc);
        assert_eq!(paths.len(), 3);
        assert_eq!(paths[2].0, "initrd");
        assert_eq!(paths[2].1, "/nix/store/ghi-initrd/initrd");
    }

    #[test]
    fn store_paths_to_root_with_hooks() {
        let mut post_launch = BTreeMap::new();
        post_launch.insert("00-setup".into(), "/nix/store/hook1/script".into());
        post_launch.insert("01-config".into(), "/home/user/local-hook.sh".into()); // not a store path

        let mut guest_init = BTreeMap::new();
        guest_init.insert("00-init".into(), "/nix/store/hook2/script".into());

        let desc = Descriptor {
            kernel: "/nix/store/abc-kernel/bzImage".into(),
            disk: "/nix/store/def-image/image.img".into(),
            initrd: None,
            cmdline: String::new(),
            configured_users: vec![],
            hooks: HooksDescriptor {
                post_launch,
                pre_stop: BTreeMap::new(),
                guest_init,
            },
        };

        let paths = store_paths_to_root(&desc);
        // kernel + disk + 1 post_launch store path + 1 guest_init store path = 4
        assert_eq!(paths.len(), 4);
        assert_eq!(paths[2].0, "hook-post-launch-00-setup");
        assert_eq!(paths[3].0, "hook-guest-init-00-init");
    }

    #[test]
    fn store_paths_to_root_skips_non_store_hooks() {
        let mut post_launch = BTreeMap::new();
        post_launch.insert("00-local".into(), "/home/user/hook.sh".into());

        let desc = Descriptor {
            kernel: "/nix/store/abc-kernel/bzImage".into(),
            disk: "/nix/store/def-image/image.img".into(),
            initrd: None,
            cmdline: String::new(),
            configured_users: vec![],
            hooks: HooksDescriptor {
                post_launch,
                pre_stop: BTreeMap::new(),
                guest_init: BTreeMap::new(),
            },
        };

        let paths = store_paths_to_root(&desc);
        assert_eq!(paths.len(), 2); // only kernel + disk
    }
}
