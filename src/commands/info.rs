use anyhow::{Result, bail};
use std::os::unix::process::CommandExt;

use epi::{instance_store, ssh, ui};

pub fn cmd_info(instance: &str) -> Result<()> {
    let state = instance_store::load_state(instance)?
        .ok_or_else(|| anyhow::anyhow!("instance {instance} not found"))?;

    let running = instance_store::instance_is_running(instance)?;

    // Build sections
    let mut sections = Vec::new();

    // Instance
    let mut identity_rows = vec![
        ("name".into(), ui::bold(instance)),
        ("target".into(), strip_home(&state.target)),
    ];
    if let Some(ref project) = state.project_dir {
        identity_rows.push(("project".into(), strip_home(project)));
    }
    identity_rows.push(("status".into(), ui::status_dot(running)));
    sections.push(InfoSection {
        heading: "instance".into(),
        rows: identity_rows,
    });

    // Resources
    sections.push(InfoSection {
        heading: "resources".into(),
        rows: vec![
            ("cpus".into(), state.cpus.to_string()),
            ("memory".into(), format!("{} MiB", state.memory_mib)),
            ("disk".into(), format_disk_size(&state.disk_size)),
        ],
    });

    // Network
    if let Some(ref rt) = state.runtime {
        let mut net_rows = Vec::new();
        if let Some(port) = rt.ssh_port {
            net_rows.push(("ssh_port".into(), port.to_string()));
            let config = ssh::config_path(instance);
            net_rows.push(("ssh_config".into(), strip_home(&config.to_string_lossy())));
        }
        if !rt.ports.is_empty() {
            let ports_str = rt
                .ports
                .iter()
                .map(|pm| format!("{}:{} ({})", pm.host, pm.guest, pm.protocol))
                .collect::<Vec<_>>()
                .join(", ");
            net_rows.push(("ports".into(), ports_str));
        }
        if !net_rows.is_empty() {
            sections.push(InfoSection {
                heading: "network".into(),
                rows: net_rows,
            });
        }
    }

    // Mounts
    if !state.mounts.is_empty() {
        let mounts_str = state
            .mounts
            .iter()
            .map(|m| strip_home(m))
            .collect::<Vec<_>>()
            .join(", ");
        sections.push(InfoSection {
            heading: "mounts".into(),
            rows: vec![("paths".into(), mounts_str)],
        });
    }

    // Runtime
    if let Some(ref rt) = state.runtime {
        let slice = instance_store::slice_name(instance, &rt.unit_id)?;
        sections.push(InfoSection {
            heading: "runtime".into(),
            rows: vec![
                ("slice".into(), slice),
                ("serial".into(), strip_home(&rt.serial_socket)),
                ("disk".into(), strip_home(&rt.disk)),
                (
                    "console".into(),
                    strip_home(&instance_store::console_log_path(instance).to_string_lossy()),
                ),
            ],
        });
    }

    let view = InfoView { sections };
    println!("{}", render_info(&view));

    Ok(())
}

/// Format a qemu-img size string (e.g. "40G") for human display (e.g. "40 GiB").
/// qemu-img uses powers of 1024 for K/M/G/T/P/E suffixes.
fn format_disk_size(size: &str) -> String {
    let suffixes = [
        ('K', "KiB"),
        ('M', "MiB"),
        ('G', "GiB"),
        ('T', "TiB"),
        ('P', "PiB"),
        ('E', "EiB"),
    ];
    if let Some(last) = size.chars().last() {
        for (ch, label) in &suffixes {
            if last == *ch {
                return format!("{} {label}", &size[..size.len() - 1]);
            }
        }
    }
    size.to_string()
}

fn strip_home(path: &str) -> String {
    ui::strip_home(path)
}

pub fn cmd_list() -> Result<()> {
    let instances = instance_store::list()?;

    if instances.is_empty() {
        println!("no instances");
        return Ok(());
    }

    let mut rows = Vec::new();
    for (name, target_str, project_dir) in &instances {
        let running = instance_store::instance_is_running(name)?;
        let status = ui::status_dot(running);
        let (ssh, ports_str) = if running {
            let rt = instance_store::find_runtime(name)?;
            let ssh = rt
                .as_ref()
                .and_then(|rt| rt.ssh_port)
                .map(|p| format!("127.0.0.1:{p}"))
                .unwrap_or_else(|| "\u{2014}".to_string());
            let ports = rt
                .as_ref()
                .map(|rt| {
                    rt.ports
                        .iter()
                        .map(|pm| format!("{}:{}", pm.host, pm.guest))
                        .collect::<Vec<_>>()
                        .join(", ")
                })
                .unwrap_or_default();
            (ssh, ports)
        } else {
            ("\u{2014}".to_string(), String::new())
        };

        rows.push(ListRow {
            name: name.clone(),
            target: strip_home(target_str),
            status,
            ssh,
            project: project_dir.as_deref().map(strip_home),
            ports: ports_str,
        });
    }

    println!("{}", render_list(&rows));

    Ok(())
}

pub fn cmd_logs(instance: &str) -> Result<()> {
    let runtime = instance_store::find_runtime(instance)?
        .ok_or_else(|| anyhow::anyhow!("instance {instance} not found or not running"))?;

    let slice = instance_store::slice_name(instance, &runtime.unit_id)?;
    let err = std::process::Command::new("journalctl")
        .args(["--user", "--unit", &slice, "--follow"])
        .exec();

    bail!("failed to exec journalctl: {err}")
}

pub fn cmd_ssh_config(instance: &str, print: bool) -> Result<()> {
    fn ensure_running(instance: &str) -> Result<()> {
        instance_store::find_runtime(instance)?
            .ok_or_else(|| anyhow::anyhow!("instance {instance} is not running"))?;
        Ok(())
    }

    ensure_running(instance)?;

    let config = ssh::config_path(instance);
    if !config.exists() {
        bail!(
            "SSH config not found for instance {instance} — it may have launched before config generation was added"
        );
    }

    if print {
        let contents = std::fs::read_to_string(&config)?;
        print!("{contents}");
    } else {
        println!("{}", config.display());
    }

    Ok(())
}

pub struct ListRow {
    pub name: String,
    pub target: String,
    pub status: String,
    pub ssh: String,
    pub project: Option<String>,
    pub ports: String,
}

pub fn render_list(rows: &[ListRow]) -> String {
    use comfy_table::{ContentArrangement, Table, presets::NOTHING};

    let has_projects = rows.iter().any(|r| r.project.is_some());

    let mut table = Table::new();
    table.load_preset(NOTHING);
    table.set_content_arrangement(ContentArrangement::Dynamic);

    if has_projects {
        table.set_header(vec![
            "INSTANCE", "TARGET", "STATUS", "SSH", "PROJECT", "PORTS",
        ]);
    } else {
        table.set_header(vec!["INSTANCE", "TARGET", "STATUS", "SSH", "PORTS"]);
    }

    for row in rows {
        if has_projects {
            let project = row.project.as_deref().unwrap_or("\u{2014}");
            table.add_row(vec![
                &row.name,
                &row.target,
                &row.status,
                &row.ssh,
                project,
                &row.ports,
            ]);
        } else {
            table.add_row(vec![
                &row.name,
                &row.target,
                &row.status,
                &row.ssh,
                &row.ports,
            ]);
        }
    }

    table.to_string()
}

pub struct InfoSection {
    pub heading: String,
    pub rows: Vec<(String, String)>,
}

pub struct InfoView {
    pub sections: Vec<InfoSection>,
}

pub fn render_info(view: &InfoView) -> String {
    use comfy_table::{Table, presets::NOTHING};

    let mut table = Table::new();
    table.load_preset(NOTHING);

    for (i, section) in view.sections.iter().enumerate() {
        if i > 0 {
            table.add_row(vec!["", ""]);
        }
        if !section.heading.is_empty() {
            table.add_row(vec![&format!("{}:", section.heading), ""]);
        }
        for (key, value) in &section.rows {
            table.add_row(vec![&format!("  {key}:"), value.as_str()]);
        }
    }

    table.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn format_disk_size_gib() {
        assert_eq!(format_disk_size("40G"), "40 GiB");
    }

    #[test]
    fn format_disk_size_mib() {
        assert_eq!(format_disk_size("512M"), "512 MiB");
    }

    #[test]
    fn format_disk_size_no_suffix() {
        assert_eq!(format_disk_size("1024"), "1024");
    }

    #[test]
    fn render_list_no_projects() {
        let rows = vec![
            ListRow {
                name: "myvm".into(),
                target: "~/.dotfiles#dev".into(),
                status: "● running".into(),
                ssh: "127.0.0.1:2222".into(),
                project: None,
                ports: "8080:80".into(),
            },
            ListRow {
                name: "other".into(),
                target: ".#test".into(),
                status: "○ stopped".into(),
                ssh: "\u{2014}".into(),
                project: None,
                ports: String::new(),
            },
        ];
        let output = render_list(&rows);
        assert!(output.contains("INSTANCE"), "should have INSTANCE header");
        assert!(output.contains("myvm"), "should contain instance name");
        assert!(output.contains("other"), "should contain second instance");
        assert!(
            !output.contains("PROJECT"),
            "should not have PROJECT column"
        );
        assert!(output.contains("8080:80"), "should contain ports");
    }

    #[test]
    fn render_list_with_projects() {
        let rows = vec![
            ListRow {
                name: "myvm".into(),
                target: "~/.dotfiles#dev".into(),
                status: "● running".into(),
                ssh: "127.0.0.1:2222".into(),
                project: Some("~/projects/foo".into()),
                ports: String::new(),
            },
            ListRow {
                name: "other".into(),
                target: ".#test".into(),
                status: "○ stopped".into(),
                ssh: "\u{2014}".into(),
                project: None,
                ports: String::new(),
            },
        ];
        let output = render_list(&rows);
        assert!(output.contains("PROJECT"), "should have PROJECT column");
        assert!(
            output.contains("~/projects/foo"),
            "should contain project path"
        );
        assert!(
            output.contains("\u{2014}"),
            "should show dash for missing project"
        );
    }

    #[test]
    fn render_list_empty() {
        let output = render_list(&[]);
        // Empty table should just have headers
        assert!(output.contains("INSTANCE"));
    }

    #[test]
    fn render_info_basic() {
        let view = InfoView {
            sections: vec![InfoSection {
                heading: "resources".into(),
                rows: vec![
                    ("cpus".into(), "4".into()),
                    ("memory".into(), "2048 MiB".into()),
                    ("disk".into(), "40 GiB".into()),
                ],
            }],
        };
        let output = render_info(&view);
        assert!(output.contains("resources:"), "should have section heading");
        assert!(output.contains("cpus:"), "should have key");
        assert!(output.contains("4"), "should have value");
        assert!(output.contains("2048 MiB"), "should have memory value");
    }

    #[test]
    fn render_info_multiple_sections() {
        let view = InfoView {
            sections: vec![
                InfoSection {
                    heading: "resources".into(),
                    rows: vec![("cpus".into(), "2".into())],
                },
                InfoSection {
                    heading: "network".into(),
                    rows: vec![("ssh_port".into(), "2222".into())],
                },
            ],
        };
        let output = render_info(&view);
        assert!(output.contains("resources:"), "should have first section");
        assert!(output.contains("network:"), "should have second section");
        assert!(output.contains("2222"), "should have ssh port value");
    }
}
