set shell := ["bash", "-euo", "pipefail", "-c"]
set positional-arguments

default:
    @just --list

versions:
    @for tool in rustc cargo rustfmt cargo-clippy deno nvim git stylua just nixfmt; do command -v "$tool"; "$tool" --version; done

format:
    stylua lua plugin tests benchmarks scripts
    cargo fmt --manifest-path daemon/Cargo.toml
    deno fmt
    nixfmt flake.nix daemon/package.nix

check:
    stylua --check lua plugin tests benchmarks scripts
    cargo fmt --check --manifest-path daemon/Cargo.toml
    deno task check
    nixfmt --check flake.nix daemon/package.nix

build:
    cargo build --locked --manifest-path daemon/Cargo.toml --target-dir daemon/target

test output=".wadackel/qa/local-ci" jobs="1": build
    cargo test --locked --manifest-path daemon/Cargo.toml --target-dir daemon/target
    deno task test --daemon "$PWD/daemon/target/debug/diffreel-daemon" --output "$1" --jobs "$2"
