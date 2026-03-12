default:
    just --list

format:
    cargo fmt
    nixfmt **/*.nix

run *args:
    cargo run -- {{ args }}

test *args:
    cargo test {{ args }}
