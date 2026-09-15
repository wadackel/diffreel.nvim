# Development guide

This guide covers a local checkout and isolated tests. Start with [contributing](../CONTRIBUTING.md); read the relevant [architecture contracts](architecture.md) before changing state, buffers, protocol, or monitoring.

- [Build and test](#build-and-test)
- [Choose checks by the change](#choose-checks-by-the-change)
- [Try the checkout in Neovim](#try-the-checkout-in-neovim)
- [Documentation and captures](#documentation-and-captures)
- [Nix package and tool updates](#nix-package-and-tool-updates)
- [Maintainer checks](#maintainer-checks)

## Build and test

Install [Nix with flakes enabled](https://nix.dev/concepts/flakes), clone the repository, and run these commands from its root:

```sh
nix develop
just versions
just check
just build
just test .wadackel/qa/local-ci
```

The development shell supports Apple Silicon macOS and Linux arm64/x86_64. [flake.lock](../flake.lock) pins Rust/Cargo, rustfmt, Clippy, Deno, Neovim, Git, StyLua, just, nixfmt, and the native build environment. Intel Mac contributors can use the [non-Nix setup](#without-nix); the plugin and distribution CI continue to support Intel Macs.

For a single command, use `nix develop --command just check`. Inside the shell, use plain `cargo`: the Nix compiler is already selected, and rustup's `cargo +version` syntax does not apply. Personal Neovim configuration and language servers are not required for the isolated suites. Dependencies are fetched on first use; the test commands use the committed Deno and Cargo lockfiles.

| Command | Purpose |
|---|---|
| `just` | List available commands |
| `just versions` | Show development tool paths and versions |
| `just format` | Format Lua, Rust, TypeScript, and Nix |
| `just check` | Check formatting and run Deno lint and type checks |
| `just build` | Build the debug daemon with locked dependencies |
| `just test [output] [jobs]` | Build the daemon, run Rust tests, then run the isolated Lua/Deno suite |

`just test` defaults to `.wadackel/qa/local-ci` and one job; pass a distinct output directory to retain each run. Use `just test .wadackel/qa/parallel 2` for up to two concurrent suite commands. Cargo output is written to `daemon/target`, and the suite receives the absolute path to `daemon/target/debug/diffreel-daemon`. Local Cargo builds identify as `local` and work with an explicit daemon path. Clippy is available for focused checks but is not part of `just check`.

CI runs `nix develop .#ci --command just check` on Linux x86_64 and Apple Silicon. The smaller `ci` shell provides static-check tools without the editor or native linker. The four native distribution jobs start after identity resolution, alongside the static checks, and use two suite jobs. Publication requires all static and native checks to pass.

### Without Nix

Use macOS or Linux with the [runtime prerequisites](../README.md#requirements), Deno 2.9.5 (pinned in [`.deno-version`](../.deno-version)), and rustup. [daemon/rust-toolchain.toml](../daemon/rust-toolchain.toml) pins the Rust compiler. Install StyLua 2.5.2 separately for Lua formatting checks.

A native linker and platform development files are also required: install Xcode Command Line Tools on macOS, or a C compiler/linker and standard development headers on Linux (for example, `build-essential` on Debian/Ubuntu). rustup does not install these system tools.

From the repository root:

```sh
rustup toolchain install 1.97.1 --profile minimal --component rustfmt
cargo +1.97.1 build --locked --manifest-path daemon/Cargo.toml
deno install --frozen --entrypoint scripts/*.ts tests/*.ts benchmarks/*.ts
deno task check
```

For a baseline Rust and UI check:

```sh
cargo +1.97.1 test --locked --manifest-path daemon/Cargo.toml
export DIFFREEL_DAEMON="$PWD/daemon/target/debug/diffreel-daemon"
nvim --headless -u NONE -i NONE -l tests/unit.lua
nvim --headless -u NONE -i NONE \
  --cmd 'let g:diffreel_daemon = $DIFFREEL_DAEMON' -l tests/ui.lua
```

For the broader isolated suite used by CI:

```sh
deno task test \
  --daemon "$PWD/daemon/target/debug/diffreel-daemon" \
  --output .wadackel/qa/local-ci
```

### Suite coverage

Both `just test` and `deno task test` run headless Lua tests, daemon shutdown, fixture checks, inline UI, UI/LSP integration, stability, exploratory regressions, and seeded stateful operation sequences. Each run records its executable and runtime versions in `environment.json`. The suite uses the TypeScript LSP server supplied in the repository. The `syntax-switch` case is excluded because it requires an installed Lua Tree-sitter parser; process-accounting tests run only on macOS. `just test` also runs Rust unit tests; when using `deno task test` directly, run those separately.

The runner accepts `--jobs <positive integer>`; the default is `1`. Each command receives its own HOME and XDG directories, while Deno dependencies share the parent's resolved `DENO_DIR`. Deno unit tests (including CPU accounting), stability, and stateful exploration run exclusively: the runner drains active commands before starting them and starts no other commands until they finish. Rust and installation tests remain separate, sequential CI steps.

Numbered logs and `results.json` retain command-list order even when commands finish out of order. Results are saved after each completion. A failing command does not skip later commands; the runner exits unsuccessfully once all commands finish. `environment.json` records `jobs` and the suite's elapsed `seconds`. Use `--jobs 1` when investigating timing-sensitive failures, and retain evidence from both execution modes.

`deno task check` checks formatting, lint rules, and types for the TypeScript tools.
`deno task test:unit` runs the `*_test.ts` tests; individual files in that group
use `deno test --frozen -A tests/support_test.ts`. Scenario scripts such as
`tests/stability.ts` use `deno run --frozen -A` and expose their arguments through
`--help`. Run these commands from the repository root. The committed lockfile
pins dependencies; CI and test subprocesses refuse implicit lockfile updates.

The tools require permission to launch Neovim, Git, and fixture processes, create
isolated repositories, and inspect the resulting files. The documented commands
grant those permissions with `-A`; macOS accounting also uses FFI. Python and a
virtual environment are not needed. Deno is not a plugin runtime dependency.

### Select the executable deliberately

| Build or caller | Executable selection |
|---|---|
| Cargo debug / release, including the Nix development shell | `daemon/target/debug/diffreel-daemon` / `daemon/target/release/diffreel-daemon` |
| `nix build` package | `result/bin/diffreel-daemon` |
| Plugin | Explicit `daemon` option, then `vim.g.diffreel_daemon`, then managed cache |
| Headless Lua tests | Pass `g:diffreel_daemon`; tests may also read `DIFFREEL_DAEMON` |
| Deno UI/shutdown tests | Set absolute `DIFFREEL_DAEMON` |
| Suite runner, stability, exploratory tests, benchmarks | Supply `--daemon` |

Building one executable does not update a configuration pointing at another. Lua changes need a fresh editor; Rust changes also need the configured executable rebuilt. A healthy worktree manager keeps its process after the last review closes.

## Choose checks by the change

Use `just build` and the applicable rows below inside `nix develop`. All Lua filenames are under `tests/`; run them using the same headless invocation and daemon environment as `tests/ui.lua` above. For focused Rust tests, use `cargo test --locked --manifest-path daemon/Cargo.toml`; outside Nix, select the pinned compiler with `cargo +1.97.1 test` instead.

| Changed behavior | Focused checks |
|---|---|
| Content, metadata, Git discovery | `unit.lua`, `repository.lua`, `content_cases.lua`, `repository_modes.lua`; Rust tests |
| Daemon lifecycle, retry, stale startup | `startup.lua`, `crash.lua`, `ui_restart.lua`, `daemon_shutdown.ts`; stability `worker-crash`, `git-failure` |
| Monitoring and comparison invalidation | `watcher.lua`, `regressions.lua`, `repository.lua`; stability `mixed-updates`, `multiple-comparisons`, `rename-reappear`, `ignore-change` |
| Explorer hierarchy, folding, path copies | `tree_actions.lua`, `tree_display_cache.lua`, `tree_clipboard.lua`, `tree_clipboard_command.lua`, `tree_ui.lua`; stability `tree-navigation`; exploratory `tree-type-change` |
| Commands, selection, tab/window lifecycle | `ui.lua`, `ui_edges.lua`, `ui_races.lua`, `exploration.lua`, `autocmd_lifecycle.lua`; stability `toggle`, `tree-navigation`, `rapid-selection`, `rapid-open-close`, `move-right-tab`, `move-clone-tab` |
| Comparison scopes, index, merge-base, preferred initial file | `options.lua`, `comparison_options.lua`, `initial_selection.lua`; Rust repository regressions, `repository.lua`, `watcher.lua`, `ui_restart.lua` |
| Explorer list/compaction/placement, sizing and single-file mode | `explorer_layout.lua`, `layout_options.lua`, `panel_ui.lua`, `explorer_resize.ts`, `path_popup.lua`, `file_mode.lua`, `navigation_edges.lua`; Rust pinned-file tests |
| Hunk navigation, mode leases and lifecycle hooks | `hunks.lua`, `hunks_ui.lua`, `keymap_modes.lua`, `events.lua`, `events_edges.lua`, `navigation_edges.lua`; existing keymap/cleanup/race suites |
| GitHub PR jobs, cache and refresh | `pr_options.lua`, `pr_backend.ts`, `pr_ui.ts`, `pr_lifecycle.ts`; Rust PR tests and existing race/cleanup suites; optional `pr_live.ts` historical fixtures |
| Command completion and keymap help | `completion.lua`, `keymap_help.lua`, `keymaps.lua`, `keymap_lease.lua`, `keymaps_ui.lua`; help-tag validation |
| Saved line counts and asynchronous pages | `line_stats.lua`, `line_stats_ui.lua`; Rust statistics regressions, `tree_display_cache.lua`, `ui_races.lua`; stats-off/on performance measurements |
| Real buffers, mappings, cleanup | `keymaps.lua`, `keymap_lease.lua`, `keymaps_ui.lua`, `cleanup_errors.lua`, `presentation.lua`, `ui_races.lua`, UI/LSP e2e; stability draft, save/undo, and navigation cases |
| Diff layouts and inline projection | `diff_layout.lua`, `layout_edges.lua`, `inline_ranges.lua`, `inline_ui.ts`; existing presentation, lease, hunk, lifecycle and race suites |
| Presentation, folds, highlighting | `highlights.lua`, `highlight_rows.lua`, `highlights_ui.ts`, `presentation.lua`, `diff_display.lua`, `probe.lua`; `syntax-switch` with a Lua parser |
| Installation and source identity | `distribution.lua`, `installer.lua`, `startup.lua`, `health.lua`, then `install_integration.ts` with a matching build ID |
| Benchmark harness | `probe.lua`, `interaction_probe.lua`, `fixtures_test.ts`, `metrics_test.ts` on macOS; a small benchmark smoke run |
| Documentation and images | Links, snippets, help tags, installation examples, and capture regeneration |

For example, select several stability regressions:

```sh
deno run --frozen -A tests/stability.ts \
  --daemon "$PWD/daemon/target/debug/diffreel-daemon" \
  --output .wadackel/qa/focused-stability \
  --cases toggle dirty-delete dirty-binary rapid-selection
```

Use `--help` or the test's `CASES` collection for available cases. Omitting `--cases` runs all of them, including `syntax-switch`. `tests/exploratory.ts` exercises API edits, shared buffers, format changes, malformed file/directory topology, and cleanup with filesystem watching disabled. Watch-driven failures are covered separately by stability tests.

For layout changes, test both initial and live transitions with a real worktree
buffer and read-only revision/PR buffers. Inline checks need compatible
window-scoped namespaces and internal diff. `inline_ranges.lua` compares the
projection to native diff across algorithms, whitespace settings, blank-line
filtering and linematch. `inline_ui.ts` attaches a real headless UI to check
virtual lines, hunk operators, drafts, folds, namespace isolation and cleanup.
Also verify an ordinary window's cached options after closing or moving a review
pane, split synchronization after layout changes, custom hunk keys, tabs and
gutter alignment, failed initial allocation, repository-aware completion, pending
selection, fallback at byte/line limits, inactive tabs and native pane closure.

### Stateful exploration and runtime variants

`tests/stateful.ts` combines edits, file selection, layout changes, Explorer
placement, external writes/deletes/renames, index and HEAD updates, and multiple
views. It checks draft preservation, closed-view lifetime and lease cleanup,
and compares prepared contents against Git at checkpoints. A failure records
its seed, operation sequence and UI grid for reproduction.

```sh
export DIFFREEL_DAEMON="$PWD/daemon/target/debug/diffreel-daemon"
deno run --frozen -A tests/stateful.ts \
  --seeds 3 4 17 318 --steps 80 --output .wadackel/qa/stateful
```

The default seeds cover watching and saved statistics both enabled and disabled.
The CI runner includes shorter sequences. Use a failing seed and the same step
count to repeat a sequence; asynchronous scheduling can still vary between runs.
The random helper preserves the previous integer-seed selection sequences;
fixed vectors verify the supported selection and sampling operations. Seeds must
fit within JavaScript's safe-integer range.

To test another Neovim release, put that release's `bin` directory first on
`PATH` for the whole runner invocation. This selects it for both the Lua tests
and editors spawned by Deno. Check the recorded `environment.json` before
interpreting the results. On Linux, run as an ordinary user so unreadable-file
fixtures actually test permission failures. Installation tests mock optional
network tools; they do not require an installed or authenticated GitHub CLI.

### Formatting

```sh
just check
git diff --check
git diff --cached --check
```

Run `just format` to apply formatting. StyLua uses [stylua.toml](../stylua.toml). Without Nix, use `stylua --check lua plugin tests benchmarks scripts docs/assets/vhs`, `cargo +1.97.1 fmt --check --manifest-path daemon/Cargo.toml`, and `deno task check`. Nix files can be formatted with `nix fmt -- flake.nix daemon/package.nix`.

### Evidence

Keep fixtures, logs, and captures in a distinct run directory under ignored `.wadackel/qa/`. Record the command, configuration, daemon path/build information, result, and any missing prerequisites. Preserve failed runs when retrying. The directory name is a repository convention; it does not require any external account or setup.

`tests/support.ts` observes a real embedded, headless Neovim UI and can save its grid as JSON, text, and SVG. Captures represent Neovim's UI, not an OS terminal window. Small benchmark runs validate the harness; they do not establish performance comparisons.

## Try the checkout in Neovim

For an isolated manual session, from the repository root:

```sh
export DIFFREEL_DAEMON="$PWD/daemon/target/debug/diffreel-daemon"
nvim -u NONE -i NONE \
  --cmd 'lua vim.opt.rtp:prepend(vim.fn.getcwd())' \
  -c 'lua vim.cmd("filetype on"); require("diffreel").setup({daemon=vim.env.DIFFREEL_DAEMON})'
```

Open a changed file in a test repository and run `:Diffreel`. For a lazy.nvim development configuration, replace the remote plugin specification with a local one:

```lua
{
  dir = "/absolute/path/to/diffreel.nvim",
  name = "diffreel.nvim",
  main = "diffreel",
  cmd = {
    "Diffreel", "DiffreelClose", "DiffreelRefresh",
    "DiffreelLayout", "DiffreelInstall", "DiffreelPRCacheClear",
  },
  keys = {
    { "<Leader>gD", "<cmd>Diffreel<CR>", desc = "Toggle diffreel" },
  },
  opts = {
    daemon = "/absolute/path/to/diffreel.nvim/daemon/target/debug/diffreel-daemon",
  },
}
```

When checking installation changes, verify the configuration actually loaded:

```vim
:lua print(debug.getinfo(require('diffreel').open, 'S').source)
:lua print(require('diffreel').config.daemon)
```

The test helper normally prepends this checkout to `runtimepath`, so ordinary UI tests alone do not prove that your package manager loads the intended installation. Use a fresh editor through the installed configuration, open and switch files, and close while retaining an unsaved draft.

Normal-config tests are optional integration checks. `--normal` uses the installed user configuration and stability's toggle case expects `,gD`. `tests/display.ts` also uses a personal configuration; its `--references` option additionally needs the comparison plugins. Those are not contributor prerequisites.

## Documentation and captures

Check relative links and anchors after moving sections. Lua snippets that are table fields or plugin specifications need their surrounding table when syntax-checking. Generate help tags in a temporary copy of `doc/`, then add that copy's parent to an isolated editor's runtimepath and open `:help diffreel`. Test command, option, and API tags, and avoid committing generated `doc/tags`.

To check package-manager examples against uncommitted documentation, copy the working-tree files into a temporary Git repository. Use that local repository as the example's source URL: set an explicit `url = "file:///..."` field for lazy.nvim, or `src = "file:///..."` for `vim.pack`. Set XDG directories before starting Neovim, then verify plugin loading and help through lazy.nvim and `vim.pack`. This includes new help files without publishing a commit.

README images are recorded from a real Neovim terminal with [VHS](https://github.com/charmbracelet/vhs). Install VHS 0.11.0, its `ffmpeg` and `ttyd` dependencies, and **JetBrainsMono Nerd Font Mono** (the regular TTF must be installed and visible to Chromium). VHS uses Chromium for rendering and may download it on first use. On Linux, `fc-match` locates the font. Recording dependencies are optional and are not included in the normal development shell.

From the repository root, build the daemon and generate one scene or all scenes:

```sh
just build
just demo review
just demo-all
```

Outside Nix, use `cargo +1.97.1 build --locked --manifest-path daemon/Cargo.toml` instead of `just build`. Set `DIFFREEL_DAEMON` to select another executable. Set `DIFFREEL_DEMO_FONT` to the installed `JetBrainsMonoNerdFontMono-Regular.ttf` if automatic discovery cannot locate it; this records the font's identity and does not install or change the font used by Chromium.

| Scene | Output | Content |
|---|---|---|
| `review` | `review.png` | Side-by-side diff and an unsaved working-tree edit |
| `layout-stacked` | `layout-stacked.png` | The same comparison in stacked layout |
| `layout-inline` | `layout-inline.png` | The same comparison in inline layout |
| `review-edit` | `review-edit.gif` | Hunk navigation, editing, and draft retention across file switching |
| `live-update` | `live-update.gif` | Filesystem updates and draft retention after an external write |

The [tapes and recording configuration](assets/vhs/) share a fixed dogrun palette, font, dimensions, and fixture. [The runner](../scripts/demo.ts) pins dogrun and nvim-web-devicons to specific commits, downloads them into `.wadackel/qa/vhs/` on first use, and reuses clean cached checkouts. No plugin manager or personal Neovim configuration is loaded. Each recording gets a separate sample Git repository, HOME, and XDG directories. Git identity and commit dates are fixed; the real checkout, index, and global Git configuration are not modified.

The tapes operate the editor with normal keys. Hidden checkpoints wait for the expected selection, layout, buffer text, disk content, and daemon snapshot; VHS waits for their completion before capturing. Sleeps control playback pacing. The live-update tape enables the real filesystem watcher and writes through a separate process. It never substitutes a manual refresh for monitoring.

Successful recordings are copied into `docs/assets/`. Each run retains its fixture, tape/configuration copies, VHS log, final GIF screenshot, `verified.json`, and `capture.json` under `.wadackel/qa/vhs/<scene>-<run>/`. Evidence includes tool versions, font and daemon checksums, source identity, dependency commits, and the fixture baseline. Failed scene verification or recording leaves the previously published asset intact.

Review PNGs and GIFs for clipping, icon alignment, readable diff colors, pacing, and agreement with their captions at README display size. Repeated runs must reproduce the scene state; byte-identical output across tool, platform, and font versions is not guaranteed. These scene checks do not replace the UI test suites.

Run `deno test --frozen -A tests/demo_test.ts` for fixture reproducibility and failed-publication checks. `just demo` validates its tape before recording. To validate a retained copy independently, run `vhs validate 'tapes/*.tape'` from that run's directory.

## Nix package and tool updates

On Apple Silicon, the Flake also provides a packaged daemon:

```sh
nix build .#default
nix flake check
```

Select `result/bin/diffreel-daemon` explicitly in configuration and tests. Nix includes Git-tracked files and their working-tree edits; stage new build inputs before building so they are included. The package runs Rust tests during its build, but an already realized successful package may be reused. It does not run the Neovim or Deno suites.

The Linux outputs provide development shells and a formatter; use `just build` for a local Linux daemon. Intel Mac has no Flake outputs because the pinned nixpkgs no longer supports that platform.

To update the tools, run `nix flake update`, then review the resulting versions. Flake evaluation requires Rust/Cargo, rustfmt, and Clippy to match [daemon/rust-toolchain.toml](../daemon/rust-toolchain.toml) and [distribution.json](../distribution.json), and Deno to match [`.deno-version`](../.deno-version). Update those pins together with the lockfile, or choose a compatible nixpkgs revision. Errors report the expected and actual versions.

After updating, run `nix flake check --all-systems --no-build`, `nix develop --command just versions`, `nix develop --command just check`, and `nix develop --command just test`. Review the non-Nix tool versions in this guide and the Neovim/Git versions and download checksums in [scripts/setup-ci.ts](../scripts/setup-ci.ts) so native CI stays aligned. Rust/Deno pin updates affect daemon identity; follow the [distribution checks](maintenance.md#distribution-identity-and-validation). The Flake lockfile itself is not a release build input, and release builds run outside the development shell.

## Maintainer checks

[Maintenance](maintenance.md) describes distribution checks, anonymous installation tests, and macOS performance measurement. These tasks are separate from the contributor build-and-test path.
