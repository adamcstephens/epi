default:
    just --list

format:
    cargo fmt
    nixfmt **/*.nix

lint:
    cargo clippy

run *args:
    cargo run -- {{ args }}

test *args:
    cargo test {{ args }}

[linux]
test-e2e *args:
    cargo test --test e2e -- --ignored --nocapture {{ args }}

# On macOS the VZ daemon must carry the virtualization entitlement, so build
# and sign the epi binary, then point the daemon at it (current_exe — the
# unsigned test binary — would be rejected by Virtualization.framework). The
# pre-built test binary is run directly: a second `cargo test` would relink
# and strip the entitlement signature off the epi binary.
[macos]
test-e2e *args:
    #!/usr/bin/env bash
    set -euo pipefail
    exe=$(cargo test --test e2e --no-run 2>&1 | tee /dev/stderr \
        | sed -n 's#.*(\(target/debug/deps/e2e-[^)]*\)).*#\1#p' | head -1)
    just sign
    EPI_VZ_DAEMON_BIN="$(pwd)/target/debug/epi" "$exe" --ignored --nocapture {{ args }}

[macos]
sign bin="target/debug/epi":
    /usr/bin/codesign --sign - --force --entitlements nix/epi.entitlements {{ bin }}
