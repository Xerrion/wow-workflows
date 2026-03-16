# Default recipe - list available recipes
default:
    @just --list

# Build the Rust binary and copy to scripts/
build:
    cargo build --release --manifest-path scripts/update-toc-versions/Cargo.toml
    cp scripts/update-toc-versions/target/release/update-toc-versions scripts/update-toc-versions.bin

# Run syntax/lint checks on all scripts
check:
    bash -n scripts/update_toc_versions.sh
    bash -n scripts/generate_changelog.sh
    cargo clippy --manifest-path scripts/update-toc-versions/Cargo.toml -- -D warnings

# Clean Rust build artifacts
clean:
    cargo clean --manifest-path scripts/update-toc-versions/Cargo.toml
    rm -f scripts/update-toc-versions.bin

# Run TOC updater (bash version - default)
toc *ARGS:
    bash scripts/update_toc_versions.sh {{ ARGS }}

# Run TOC updater (Bun/TypeScript version)
toc-bun *ARGS:
    bun scripts/update_toc_versions.ts {{ ARGS }}

# Run TOC updater (Rust version - uses prebuilt binary if available)
toc-rust *ARGS:
    #!/usr/bin/env bash
    if [[ -x scripts/update-toc-versions.bin ]]; then
        scripts/update-toc-versions.bin {{ ARGS }}
    else
        cargo run --release --manifest-path scripts/update-toc-versions/Cargo.toml -- {{ ARGS }}
    fi

# Generate changelog
changelog *ARGS:
    bash scripts/generate_changelog.sh {{ ARGS }}
