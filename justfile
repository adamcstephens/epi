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
    cargo test --test e2e -- --ignored --skip e2e_cpus_override {{ args }}

# Release: just release 0.3.0
release version:
    sed -i 's/^version = ".*"/version = "{{ version }}"/' Cargo.toml
    cargo generate-lockfile --offline
    jj commit --message "release {{ version }}" Cargo.*
    git tag "v{{ version }}"
    git push origin "v{{ version }}"
