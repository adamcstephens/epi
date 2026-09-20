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
fn store_paths_to_root<'a>(
    desc: &'a Descriptor,
    configured: &'a instance_store::HostHooks,
) -> Vec<(String, &'a str)> {
    let mut paths = Vec::new();

    paths.push(("kernel".to_string(), desc.kernel.as_str()));
    if !desc.toplevel.is_empty() {
        paths.push(("toplevel".to_string(), desc.toplevel.as_str()));
    }
    paths.push(("disk".to_string(), desc.disk.as_str()));

    if let Some(ref initrd) = desc.initrd {
        paths.push(("initrd".to_string(), initrd.as_str()));
    }

    for (name, script) in &desc.hooks.post_launch {
        if target::is_nix_store_path(script) {
            paths.push((format!("hook-post-launch-{name}"), script.as_str()));
        }
    }
    for (name, script) in &desc.hooks.post_start {
        if target::is_nix_store_path(script) {
            paths.push((format!("hook-post-start-{name}"), script.as_str()));
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
    for (point, scripts) in [
        ("post-launch", &configured.post_launch),
        ("post-start", &configured.post_start),
        ("pre-stop", &configured.pre_stop),
    ] {
        for (index, script) in scripts.values().enumerate() {
            if target::is_nix_store_path(script) {
                paths.push((format!("configured-{point}-{index}"), script.as_str()));
            }
        }
    }

    paths
}

/// Create GC roots for all nix store paths referenced by the descriptor.
///
/// Each root is a symlink in `.epi/state/<instance>/gcroots/<label>` registered
/// via `nix-store --add-root --realise`.
pub fn create(
    instance: &str,
    desc: &Descriptor,
    configured: &instance_store::HostHooks,
) -> Result<()> {
    let dir = gcroots_dir(instance);
    fs::create_dir_all(&dir).with_context(|| format!("creating gcroots dir: {}", dir.display()))?;

    let paths = store_paths_to_root(desc, configured);
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
    fn store_paths_to_root_with_hooks() {
        let mut post_launch = BTreeMap::new();
        post_launch.insert("00-setup".into(), "/nix/store/hook1/script".into());
        post_launch.insert("01-config".into(), "/home/user/local-hook.sh".into()); // not a store path

        let mut post_start = BTreeMap::new();
        post_start.insert("00-resume".into(), "/nix/store/resume/script".into());
        post_start.insert("01-local".into(), "/home/user/resume.sh".into());

        let mut guest_init = BTreeMap::new();
        guest_init.insert("00-init".into(), "/nix/store/hook2/script".into());

        let desc = Descriptor {
            toplevel: String::new(),
            kernel: "/nix/store/abc-kernel/bzImage".into(),
            disk: "/nix/store/def-image/image.qcow2".into(),
            initrd: None,
            cmdline: String::new(),
            configured_users: vec![],
            hooks: HooksDescriptor {
                post_launch,
                post_start,
                pre_stop: BTreeMap::new(),
                guest_init,
            },
        };

        let configured = instance_store::HostHooks {
            post_start: BTreeMap::from([
                ("00-local".into(), "/home/user/configured-resume.sh".into()),
                (
                    "01-resume".into(),
                    "/nix/store/configured-resume/script".into(),
                ),
            ]),
            ..Default::default()
        };
        let paths = store_paths_to_root(&desc, &configured);
        assert_eq!(
            paths,
            vec![
                ("kernel".into(), "/nix/store/abc-kernel/bzImage"),
                ("disk".into(), "/nix/store/def-image/image.qcow2"),
                (
                    "hook-post-launch-00-setup".into(),
                    "/nix/store/hook1/script"
                ),
                (
                    "hook-post-start-00-resume".into(),
                    "/nix/store/resume/script"
                ),
                ("hook-guest-init-00-init".into(), "/nix/store/hook2/script"),
                (
                    "configured-post-start-1".into(),
                    "/nix/store/configured-resume/script"
                ),
            ]
        );
    }
}
