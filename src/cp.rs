use anyhow::Result;

/// A parsed copy endpoint — either a local path or a remote instance path.
#[derive(Debug, PartialEq)]
pub enum Endpoint {
    Local(String),
    Remote { instance: String, path: String },
}

/// Parsed source and destination for a cp command.
#[derive(Debug, PartialEq)]
pub struct CopySpec {
    pub source: Endpoint,
    pub dest: Endpoint,
}

/// Parse a single path argument into an Endpoint.
///
/// Split on the first `:` — if there is a left side (possibly empty),
/// treat it as remote. An empty left side means the default instance.
/// Absolute paths (starting with `/`) are always local.
pub fn parse_endpoint(s: &str) -> Endpoint {
    if let Some(idx) = s.find(':') {
        let left = &s[..idx];
        let right = &s[idx + 1..];

        // Absolute paths like /foo/bar are always local
        if left.is_empty() && right.starts_with('/') {
            return Endpoint::Local(s.to_string());
        }

        // If left is empty, use default instance
        let instance = if left.is_empty() {
            "default".to_string()
        } else {
            left.to_string()
        };

        Endpoint::Remote {
            instance,
            path: right.to_string(),
        }
    } else {
        Endpoint::Local(s.to_string())
    }
}

/// Parse source and destination arguments into a CopySpec.
///
/// At least one side must be remote.
pub fn parse_copy_spec(source: &str, dest: &str) -> Result<CopySpec> {
    let source = parse_endpoint(source);
    let dest = parse_endpoint(dest);

    match (&source, &dest) {
        (Endpoint::Local(_), Endpoint::Local(_)) => {
            anyhow::bail!("at least one side must be a remote instance (use <instance>:<path>)")
        }
        (Endpoint::Remote { .. }, Endpoint::Remote { .. }) => {
            anyhow::bail!("copying between two remote instances is not supported")
        }
        _ => Ok(CopySpec { source, dest }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_local_path() {
        assert_eq!(
            parse_endpoint("./file.txt"),
            Endpoint::Local("./file.txt".to_string())
        );
    }

    #[test]
    fn parse_absolute_local_path() {
        assert_eq!(
            parse_endpoint("/tmp/file.txt"),
            Endpoint::Local("/tmp/file.txt".to_string())
        );
    }

    #[test]
    fn parse_host_to_remote() {
        assert_eq!(
            parse_endpoint("myvm:/tmp/file.txt"),
            Endpoint::Remote {
                instance: "myvm".to_string(),
                path: "/tmp/file.txt".to_string(),
            }
        );
    }

    #[test]
    fn parse_remote_to_host() {
        assert_eq!(
            parse_endpoint("myvm:/var/log/syslog"),
            Endpoint::Remote {
                instance: "myvm".to_string(),
                path: "/var/log/syslog".to_string(),
            }
        );
    }

    #[test]
    fn parse_default_instance() {
        assert_eq!(
            parse_endpoint(":~/file"),
            Endpoint::Remote {
                instance: "default".to_string(),
                path: "~/file".to_string(),
            }
        );
    }

    #[test]
    fn parse_copy_spec_host_to_remote() {
        let spec = parse_copy_spec("./file.txt", "myvm:/tmp/file.txt").unwrap();
        assert_eq!(spec.source, Endpoint::Local("./file.txt".to_string()));
        assert_eq!(
            spec.dest,
            Endpoint::Remote {
                instance: "myvm".to_string(),
                path: "/tmp/file.txt".to_string(),
            }
        );
    }

    #[test]
    fn parse_copy_spec_remote_to_host() {
        let spec = parse_copy_spec("myvm:/var/log/syslog", "./syslog").unwrap();
        assert_eq!(
            spec.source,
            Endpoint::Remote {
                instance: "myvm".to_string(),
                path: "/var/log/syslog".to_string(),
            }
        );
        assert_eq!(spec.dest, Endpoint::Local("./syslog".to_string()));
    }

    #[test]
    fn parse_copy_spec_both_local_fails() {
        let err = parse_copy_spec("./a", "./b").unwrap_err();
        assert!(
            err.to_string()
                .contains("at least one side must be a remote instance")
        );
    }

    #[test]
    fn parse_copy_spec_both_remote_fails() {
        let err = parse_copy_spec("vm1:/a", "vm2:/b").unwrap_err();
        assert!(err.to_string().contains("not supported"));
    }
}
