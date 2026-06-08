//! Translate vfrust / Virtualization.framework errors into actionable,
//! user-facing messages instead of raw NSError dumps.

use vfrust::{Error, VzErrorCode};

/// Render a vfrust error as a user-facing message, mapping common
/// `VzErrorCode` cases to guidance. The wrapped NSError message (localized
/// description) is appended where it adds detail.
pub fn friendly_error(err: &Error) -> String {
    match err {
        Error::VzError { code, message } => friendly_vz_code(*code, message),
        Error::InvalidConfiguration(m)
        | Error::InvalidDevice(m)
        | Error::InvalidBootloader(m)
        | Error::ValidationFailed(m) => {
            with_entitlement_hint(format!("the VM configuration is invalid: {m}"), m)
        }
        Error::FileNotFound(p) => format!("a required file is missing: {}", p.display()),
        Error::RequiresAppleSilicon => {
            "epi's macOS backend requires Apple Silicon (Virtualization.framework)".into()
        }
        Error::RosettaUnavailable => {
            "Rosetta is not available on this system; install it or disable Rosetta in the config"
                .into()
        }
        Error::Timeout => "the Virtualization.framework operation timed out".into(),
        // I/O and dispatch errors already read clearly via Display.
        other => other.to_string(),
    }
}

/// Append codesigning guidance when an error mentions the missing
/// virtualization entitlement (Virtualization.framework surfaces this as a
/// plain validation failure, not a typed code).
fn with_entitlement_hint(msg: String, detail: &str) -> String {
    if detail.to_lowercase().contains("entitlement") {
        format!(
            "{msg} — the binary needs the com.apple.security.virtualization \
             entitlement; run `just sign` for a dev build or check codesigning."
        )
    } else {
        msg
    }
}

fn friendly_vz_code(code: VzErrorCode, message: &str) -> String {
    let detail = if message.is_empty() {
        String::new()
    } else {
        format!(" ({message})")
    };
    match code {
        VzErrorCode::InvalidVirtualMachineConfiguration => format!(
            "Virtualization.framework rejected the VM configuration{detail}. \
             If the binary isn't codesigned with the \
             com.apple.security.virtualization entitlement the VM cannot start \
             — run `just sign` for a dev build, or check codesigning."
        ),
        VzErrorCode::InvalidDiskImage => {
            format!("the disk image is invalid or unreadable{detail}")
        }
        VzErrorCode::OutOfDiskSpace => {
            format!("the host is out of disk space{detail}")
        }
        VzErrorCode::NotSupported => {
            format!("the requested VM feature is not supported on this host{detail}")
        }
        VzErrorCode::VirtualMachineLimitExceeded => format!(
            "too many virtual machines are already running \
             (Virtualization.framework limit){detail}"
        ),
        VzErrorCode::NetworkError => {
            format!("the VM's network device failed to initialize{detail}")
        }
        VzErrorCode::InvalidVirtualMachineState
        | VzErrorCode::InvalidVirtualMachineStateTransition => {
            format!("the VM was in an unexpected state for this operation{detail}")
        }
        VzErrorCode::OperationCancelled => format!("the VM operation was cancelled{detail}"),
        VzErrorCode::Internal => {
            format!("Virtualization.framework reported an internal error{detail}")
        }
        VzErrorCode::Unknown(c) => {
            format!("Virtualization.framework error (code {c}){detail}")
        }
        // Save/restore and NBD/USB codes aren't reachable from epi's config.
        other => format!("Virtualization.framework error ({other:?}){detail}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn invalid_config_mentions_entitlement() {
        let msg = friendly_error(&Error::VzError {
            code: VzErrorCode::InvalidVirtualMachineConfiguration,
            message: "boom".into(),
        });
        assert!(msg.contains("entitlement"), "{msg}");
        assert!(msg.contains("just sign"), "{msg}");
        assert!(msg.contains("boom"), "appends NSError detail: {msg}");
    }

    #[test]
    fn disk_image_error_is_specific() {
        let msg = friendly_error(&Error::VzError {
            code: VzErrorCode::InvalidDiskImage,
            message: "bad".into(),
        });
        assert!(msg.contains("disk image"), "{msg}");
        assert!(
            !msg.to_lowercase().contains("nserror"),
            "no raw dump: {msg}"
        );
    }

    #[test]
    fn out_of_disk_space_is_clear() {
        let msg = friendly_error(&Error::VzError {
            code: VzErrorCode::OutOfDiskSpace,
            message: String::new(),
        });
        assert!(msg.contains("out of disk space"), "{msg}");
        // No empty parens when there's no detail.
        assert!(!msg.contains("()"), "{msg}");
    }

    #[test]
    fn unknown_code_includes_number() {
        let msg = friendly_error(&Error::VzError {
            code: VzErrorCode::Unknown(4242),
            message: "x".into(),
        });
        assert!(msg.contains("4242"), "{msg}");
    }

    #[test]
    fn config_validation_variants_collapse() {
        let msg = friendly_error(&Error::ValidationFailed("cpus must be at least 1".into()));
        assert!(msg.contains("configuration is invalid"), "{msg}");
        assert!(msg.contains("cpus must be at least 1"), "{msg}");
        // No entitlement noise for unrelated validation failures.
        assert!(!msg.contains("just sign"), "{msg}");
    }

    #[test]
    fn entitlement_validation_failure_adds_codesign_hint() {
        // This is how VZ actually reports a missing entitlement: a plain
        // ValidationFailed whose message names the entitlement.
        let msg = friendly_error(&Error::ValidationFailed(
            "Invalid virtual machine configuration. The process doesn’t have the \
             “com.apple.security.virtualization” entitlement."
                .into(),
        ));
        assert!(msg.contains("just sign"), "{msg}");
        assert!(msg.contains("entitlement"), "{msg}");
    }

    #[test]
    fn apple_silicon_requirement_is_plain() {
        let msg = friendly_error(&Error::RequiresAppleSilicon);
        assert!(msg.contains("Apple Silicon"), "{msg}");
    }
}
