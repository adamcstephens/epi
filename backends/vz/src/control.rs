//! JSON-lines control protocol between epi CLI processes and the
//! per-instance `epi __vmm-daemon` that holds the VZ virtual machine.
//!
//! One JSON object per line. Every message carries a `version` field for
//! forward compatibility; the daemon rejects versions it doesn't know.
//! Linux needs none of this — systemd serves the CLI↔backend role there.

use anyhow::{Context, Result, bail};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

use epi_core::backend::InstanceStatus;

pub const PROTOCOL_VERSION: u32 = 1;

/// Responses are sent immediately (shutdown work continues after the
/// reply), so a short read timeout is enough to detect a wedged daemon.
const REPLY_TIMEOUT: Duration = Duration::from_secs(5);

/// Per-instance control socket, next to the rest of the instance state.
pub fn socket_path(instance_dir: &Path) -> PathBuf {
    instance_dir.join("control.sock")
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "verb", rename_all = "snake_case")]
pub enum Request {
    /// Query VM liveness.
    Status,
    /// Graceful guest shutdown; the daemon force-stops after the grace
    /// period and exits.
    Stop { grace_seconds: u64 },
    /// Force-stop the VM immediately; the daemon exits.
    KillNow,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "outcome", rename_all = "snake_case")]
pub enum Response {
    Status { status: InstanceStatus },
    Stopping,
    Killed,
    Error { message: String },
}

/// Versioned wire envelope around requests and responses.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct Envelope<T> {
    version: u32,
    #[serde(flatten)]
    body: T,
}

/// Serialize a message to its single-line wire form (no trailing newline).
pub fn encode<T: Serialize>(body: &T) -> Result<String> {
    serde_json::to_string(&Envelope {
        version: PROTOCOL_VERSION,
        body,
    })
    .context("encoding control message")
}

/// Parse a wire line, rejecting unknown protocol versions.
pub fn decode<T: DeserializeOwned>(line: &str) -> Result<T> {
    let envelope: Envelope<T> =
        serde_json::from_str(line.trim_end()).context("parsing control message")?;
    if envelope.version != PROTOCOL_VERSION {
        bail!(
            "unsupported control protocol version {} (this epi speaks {PROTOCOL_VERSION})",
            envelope.version
        );
    }
    Ok(envelope.body)
}

/// Send one request over the instance control socket and read the reply.
/// One connection per request.
pub fn send_request(socket: &Path, request: &Request) -> Result<Response> {
    let mut stream = UnixStream::connect(socket)
        .with_context(|| format!("connecting to vmm daemon: {}", socket.display()))?;
    stream.set_read_timeout(Some(REPLY_TIMEOUT))?;
    stream.set_write_timeout(Some(REPLY_TIMEOUT))?;

    let line = encode(request)?;
    writeln!(stream, "{line}").context("sending control request")?;

    let mut reply = String::new();
    BufReader::new(stream)
        .read_line(&mut reply)
        .context("reading control response")?;
    if reply.is_empty() {
        bail!("vmm daemon closed the connection without responding");
    }
    decode(&reply)
}

#[cfg(test)]
mod tests {
    use super::*;
    use epi_core::backend::InstanceStatus;
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::net::UnixListener;
    use std::path::PathBuf;
    use tempfile::TempDir;

    #[test]
    fn socket_path_is_in_instance_dir() {
        assert_eq!(
            socket_path(&PathBuf::from("/inst/testvm")),
            PathBuf::from("/inst/testvm/control.sock")
        );
    }

    #[test]
    fn request_wire_shape() {
        let line = encode(&Request::Stop { grace_seconds: 20 }).unwrap();
        assert!(line.contains(r#""version":1"#), "{line}");
        assert!(line.contains(r#""verb":"stop""#), "{line}");
        assert!(line.contains(r#""grace_seconds":20"#), "{line}");
        assert!(!line.contains('\n'), "encode emits a single line");

        let status = encode(&Request::Status).unwrap();
        assert!(status.contains(r#""verb":"status""#), "{status}");
        let kill = encode(&Request::KillNow).unwrap();
        assert!(kill.contains(r#""verb":"kill_now""#), "{kill}");
    }

    #[test]
    fn response_wire_shape() {
        let line = encode(&Response::Status {
            status: InstanceStatus::Running,
        })
        .unwrap();
        assert!(line.contains(r#""outcome":"status""#), "{line}");
        assert!(line.contains(r#""status":"running""#), "{line}");

        let err = encode(&Response::Error {
            message: "boom".into(),
        })
        .unwrap();
        assert!(err.contains(r#""outcome":"error""#), "{err}");
        assert!(err.contains(r#""message":"boom""#), "{err}");
    }

    #[test]
    fn roundtrip_all_requests() {
        for req in [
            Request::Status,
            Request::Stop { grace_seconds: 0 },
            Request::Stop { grace_seconds: 20 },
            Request::KillNow,
        ] {
            let line = encode(&req).unwrap();
            let decoded: Request = decode(&line).unwrap();
            assert_eq!(decoded, req);
        }
    }

    #[test]
    fn roundtrip_all_responses() {
        for resp in [
            Response::Status {
                status: InstanceStatus::Running,
            },
            Response::Status {
                status: InstanceStatus::Stopped,
            },
            Response::Stopping,
            Response::Killed,
            Response::Error {
                message: "nope".into(),
            },
        ] {
            let line = encode(&resp).unwrap();
            let decoded: Response = decode(&line).unwrap();
            assert_eq!(decoded, resp);
        }
    }

    #[test]
    fn decode_rejects_unknown_version() {
        let line = r#"{"version":999,"verb":"status"}"#;
        let err = decode::<Request>(line).unwrap_err();
        assert!(err.to_string().contains("version"), "{err}");
    }

    #[test]
    fn decode_rejects_malformed_json() {
        assert!(decode::<Request>("not json").is_err());
        assert!(decode::<Request>(r#"{"version":1}"#).is_err());
    }

    /// Mock daemon: serves `conns` connections, one request per connection
    /// (the client connects per request), answering each verb like the real
    /// supervisor will.
    fn spawn_mock_daemon(socket: PathBuf, conns: usize) -> std::thread::JoinHandle<()> {
        let listener = UnixListener::bind(&socket).unwrap();
        std::thread::spawn(move || {
            for stream in listener.incoming().take(conns) {
                let stream = stream.unwrap();
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut writer = stream;
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                let response = match decode::<Request>(&line) {
                    Ok(Request::Status) => Response::Status {
                        status: InstanceStatus::Running,
                    },
                    Ok(Request::Stop { .. }) => Response::Stopping,
                    Ok(Request::KillNow) => Response::Killed,
                    Err(e) => Response::Error {
                        message: e.to_string(),
                    },
                };
                writeln!(writer, "{}", encode(&response).unwrap()).unwrap();
            }
        })
    }

    #[test]
    fn send_request_roundtrips_against_mock_daemon() {
        let dir = TempDir::new().unwrap();
        let socket = socket_path(dir.path());
        let server = spawn_mock_daemon(socket.clone(), 3);

        assert_eq!(
            send_request(&socket, &Request::Status).unwrap(),
            Response::Status {
                status: InstanceStatus::Running
            }
        );
        assert_eq!(
            send_request(&socket, &Request::Stop { grace_seconds: 5 }).unwrap(),
            Response::Stopping
        );
        assert_eq!(
            send_request(&socket, &Request::KillNow).unwrap(),
            Response::Killed
        );
        drop(server);
    }

    #[test]
    fn send_request_errors_when_daemon_absent() {
        let dir = TempDir::new().unwrap();
        let socket = socket_path(dir.path());
        assert!(send_request(&socket, &Request::Status).is_err());
    }
}
