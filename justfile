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

test-e2e *args:
    cargo test --test e2e -- --ignored --nocapture {{ args }}

# Release: just release 0.3.0
release version:
    sed -i 's/^version = ".*"/version = "{{ version }}"/' Cargo.toml
    cargo generate-lockfile --offline
    jj commit --message "release {{ version }}" Cargo.*
    jj bookmark move main --to @-
    git tag -a "v{{ version }}" -m "release {{ version }}"
    git push origin "v{{ version }}"
    jj git push
