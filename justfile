default:
    just --list

format:
    cargo fmt
    nixfmt **/*.nix

run *args:
    cargo run -- {{ args }}

test *args:
    cargo test {{ args }}

test-e2e *args:
    cargo test --test e2e -- --ignored --test-threads=1 {{ args }}
