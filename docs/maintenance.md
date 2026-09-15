# Maintenance

For ordinary code changes, use the [development guide](development.md). This document covers binary distribution and measurement. [Architecture](architecture.md#daemon-distribution-and-startup) explains installation ownership and integrity.

## Distribution identity and validation

[daemon/rust-toolchain.toml](../daemon/rust-toolchain.toml) pins Rust 1.97.1. [distribution.json](../distribution.json) defines supported distribution targets and protocol settings. [distribution.lua](../lua/diffreel/distribution.lua) is the build-ID implementation used by both CI and installed plugins.

The ID includes Rust sources, Cargo inputs, build metadata, distribution settings, build/validation scripts, the pinned Deno version, and identity code. UI, documentation, tests, and generated files do not participate. Changing the native build recipe or accepted dynamic dependencies must change a hashed input. Do not add timestamps or commit SHAs to the ID.

The binary validator runs with `deno run --no-config -A` and uses no imported
dependencies. The test tools' `deno.json` and `deno.lock` therefore do not affect
daemon identity. A validator or Deno-version change produces a new ID; older
releases remain available to pinned plugin versions.

```sh
nvim --headless -u NONE -i NONE -l scripts/build-id.lua
nvim --headless -u NONE -i NONE -l tests/distribution.lua
nvim --headless -u NONE -i NONE -l tests/installer.lua
nvim --headless -u NONE -i NONE -l tests/startup.lua
nvim --headless -u NONE -i NONE -l tests/health.lua
```

The real HTTP/concurrent-editor fixture needs a daemon built with the current ID. From the repository root:

```sh
diffreel_build_id=$(nvim --headless -u NONE -i NONE -l scripts/build-id.lua)
DIFFREEL_BUILD_ID="$diffreel_build_id" cargo +1.97.1 build --locked --manifest-path daemon/Cargo.toml
deno run --frozen -A tests/install_integration.ts --daemon daemon/target/debug/diffreel-daemon
```

This local test binary can use development-toolchain libraries; it is not a release artifact. The fixture exercises concurrent installs, verified cache use, corruption/retry, close and exit during fetch, fresh installation/update hooks, and rollback. Unit-level installer tests cover malformed artifacts, HTTP failures and missing curl, timeout, and stale callbacks.

## Release workflow

The [CI workflow](../.github/workflows/ci.yml) validates four native targets:

| Target | Runner | Binary requirement |
|---|---|---|
| aarch64-apple-darwin | macos-14 | macOS 14 minimum, Apple system libraries, ad-hoc signature |
| x86_64-apple-darwin | macos-15-intel | macOS 14 minimum, Apple system libraries, ad-hoc signature |
| aarch64-unknown-linux-musl | ubuntu-24.04-arm | Static ELF for arm64 |
| x86_64-unknown-linux-musl | ubuntu-24.04 | Static ELF for x86_64 |

CI uses Neovim 0.12.5 and Git 2.55.0. Native jobs build an absent ID or reuse a validated complete release, execute the binary, and run Rust and Neovim tests. Release builds run outside Nix; macOS artifacts must not link Nix-store or Homebrew libraries.

Only trusted main pushes and manual main workflow runs can publish. Publication is serialized per ID. All four executables and `manifest.json` are uploaded and verified while the release is a draft, then published as an exact-ID prerelease. Completed releases remain immutable; UI-only changes reuse them. Old release IDs remain available for pinned plugins and rollback.

Post-publication [consumer tests](../tests/consumer.ts) install through lazy.nvim and `vim.pack` at the workflow's tested commit SHA. A Deno parent drives Neovim with an isolated runtime-only PATH that excludes gh, Deno, Python, Cargo, rustc, and Nix. The tests cover anonymous downloads, cache reuse, review updates, draft preservation, and close. The editor receives an allowlisted environment with isolated HOME/XDG directories, no authentication tokens, and system/global Git configuration disabled. These tests do not prepend the development checkout to runtimepath.

For workflow changes, run the available static checks:

```sh
actionlint .github/workflows/ci.yml
zizmor --offline .github/workflows/ci.yml
ravelact build --root . --no-cache
ravelact permissions --root . --no-cache
ravelact secrets --root . --no-cache
ravelact wiring --root . --no-cache
```

## Public availability

Source installation and cold daemon downloads must work without GitHub authentication. The post-publication consumer jobs verify both package managers on all four supported targets at the tested commit SHA. They check the loaded plugin path, installed commit, build ID, and review behavior.

To repeat this check locally after publication:

```sh
DIFFREEL_COMMIT="$(git rev-parse HEAD)" \
DIFFREEL_EXPECTED_ID="$(nvim --headless -u NONE -i NONE -l scripts/build-id.lua)" \
deno run --frozen -A tests/consumer.ts
```

Local HTTP fixtures verify transport and lifecycle behavior; the consumer jobs verify actual GitHub delivery. Maintainer release operations use GitHub CLI authentication, while end-user installation does not. The release lifecycle tests use a local GitHub CLI fixture to cover initial publication, interrupted drafts, and immutable release reuse.

## Performance measurement

The benchmark runner is macOS-specific. It creates deterministic S/M/L/XL repositories and measures the Rust backend under minimal or normal configuration. Use an explicit daemon path and record the compiler that built it. For a Nix build, inspect the pinned compiler with:

```sh
nix eval --impure --raw --expr \
  '(builtins.getFlake ("git+file://" + toString ./.)).inputs.nixpkgs.legacyPackages.${builtins.currentSystem}.rustc.version'
```

For a small harness smoke run, from the repository root:

```sh
deno run --frozen -A benchmarks/run.ts \
  --fixtures .wadackel/qa/benchmark-smoke/fixtures \
  --output .wadackel/qa/benchmark-smoke \
  --daemon "$PWD/daemon/target/debug/diffreel-daemon" \
  --daemon-compiler 'rustc 1.97.1 (Cargo debug)' \
  --cases S --contexts minimal \
  --samples 2 --cold-samples 1 --live-samples 1 --idle-seconds 0
```

For measurement, use a release build, record its actual compiler, and increase sample counts, for example `--samples 30 --cold-samples 3 --live-samples 10 --idle-seconds 32`. Choose fixture cases and contexts explicitly. Normal-context runs require an installed user configuration with working vtsls hover; minimal runs do not.

Warm sessions preload both selected files. Normal sessions also complete a vtsls hover and wait for CPU quiescence. Live trials write changed files once per second with one editor active. M uses a fixed HEAD~20 baseline; fixture Git fsmonitor is disabled. Keep source files unchanged during a run.

Latency ends only after full expected content and diff state are validated and the attached UI receives a subsequent flush. A cold trial starts a fresh editor and daemon without clearing OS caches; editor startup is recorded separately. CPU includes descendants and reaped children using calibrated macOS counters. Phase CPU through quiescence is the primary CPU measure. Sampled RSS/footprint maxima are not absolute peaks.

Raw trials, process samples, spawn causes, environment, source/binary hashes, and summaries are stored in the output's `artifacts/` directory. Report sample counts and measurement limits. A smoke run validates execution; it does not support a performance claim. See the [measurement contract](architecture.md#measurement-contract).

The Deno harness records its runtime and dependency identities. macOS counters
are read through FFI as 64-bit integers; process start identifiers are serialized
as decimal strings to preserve their precision. CPU durations and byte counts
remain numeric. Keep results from different harness revisions separate when
comparing latency: observer scheduling is part of the recorded endpoint.

### Explorer and editing interactions

[interactions.ts](../benchmarks/interactions.ts) measures warm file switching, whole-tree folding and unsaved buffer edits with larger changed-file sets:

```sh
deno run --frozen -A benchmarks/interactions.ts \
  --source /absolute/path/to/frozen-checkout \
  --daemon "$PWD/daemon/target/release/diffreel-daemon" \
  --daemon-compiler 'rustc 1.97.1 (Cargo release)' \
  --fixtures .wadackel/qa/interactions/fixtures \
  --output .wadackel/qa/interactions/before \
  --changed-files 100 1000 --samples 30
```

Use separate, unchanged source snapshots for before/after runs and repeat them in alternating order. Keep the daemon and measurement harness identical within each comparison. Do not run other tests or benchmarks concurrently. `--normal` adds installed configuration and a real vtsls hover warmup; the loaded diffreel module paths are checked against `--source` in either mode. Operations run back-to-back by default. Use `--interval-ms 100` for a fixed input cadence when comparing normal-configuration CPU, since faster input can change LSP batching.

The measurement process explicitly loads the frozen diffreel modules from `--source`. Other installed plugins and settings remain active in normal mode. This makes source selection independent of lazy-loader caches; verify the actual installed plugin path separately using the deployment check in the development guide.

Each fixture has regular text files under one directory. Watching is disabled to isolate UI work. A sample completes only after full diff content, snapshot metadata, Explorer text, status/selection highlights, conflict footer and fold state match, followed by an attached UI flush. Validation overhead is included in the latency. Phase CPU extends through quiescence; memory values are sampled observations. Warm phases must perform no Git spawns.

Folding uses the default `gE`/`gW` bindings. The edit phase replaces the generated buffer through Neovim's API. Normal-context CPU includes asynchronous LSP work and may remain variable even with a fixed input cadence; report that separately from the time until the verified UI frame.

The output contains source/harness/binary identities, raw trials, process samples and captures. This benchmark does not measure cold startup, installation or live filesystem reconciliation; use the main runner for those scenarios. A two-sample run checks the harness only. Run `tests/probe.lua` and `tests/interaction_probe.lua` after changing readiness validation.

Add `--line-stats` to measure warm interactions with saved line counts enabled. Startup waits for every fixture count and the rendered total; readiness checks validate those values, their generation and the per-file labels. This adds validation work to measured latency. Counting itself is outside the warm interaction phase, so these measurements do not establish the time to finish an initial statistics scan.
