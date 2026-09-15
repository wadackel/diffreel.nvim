#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
target="$1"
output="$2"
build_id="$3"
rust_version=$(deno eval --no-config 'console.log(JSON.parse(Deno.readTextFileSync("distribution.json")).rust)')
deno eval --no-config 'if (!JSON.parse(Deno.readTextFileSync("distribution.json")).targets.includes(Deno.args[0])) throw new Error("Unsupported target")' "$target"
unset RUSTFLAGS CARGO_ENCODED_RUSTFLAGS LIBRARY_PATH DYLD_LIBRARY_PATH LD_LIBRARY_PATH
unset NIX_LDFLAGS NIX_CFLAGS_COMPILE NIX_CFLAGS_LINK CARGO_BUILD_TARGET
export DIFFREEL_BUILD_ID="$build_id"
case "$target" in
  *-apple-darwin)
    export MACOSX_DEPLOYMENT_TARGET=14.0
    export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
    export CC=/usr/bin/clang
    export CXX=/usr/bin/clang++
    ;;
  *-linux-musl)
    export CC=musl-gcc
    export RUSTFLAGS='-C target-feature=+crt-static'
    ;;
esac
rustup target add --toolchain "$rust_version" "$target"
cargo "+$rust_version" build --release --locked --manifest-path daemon/Cargo.toml --target "$target"
mkdir -p "$output"
binary="$output/diffreel-daemon-$target"
cp "daemon/target/$target/release/diffreel-daemon" "$binary"
case "$target" in
  *-apple-darwin) codesign --force --sign - "$binary" ;;
esac
deno run --no-config -A scripts/validate-daemon.ts "$binary" "$target" "$build_id"
