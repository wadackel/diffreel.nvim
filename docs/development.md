# Development guide

This guide covers a local checkout and isolated tests. Start with [contributing](../CONTRIBUTING.md); read the relevant [architecture contracts](architecture.md) before changing state, buffers, protocol, or monitoring.

- [Build and test](#build-and-test)
- [Choose checks by the change](#choose-checks-by-the-change)
- [Try the checkout in Neovim](#try-the-checkout-in-neovim)
- [Documentation and captures](#documentation-and-captures)
- [Optional Nix environment](#optional-nix-environment)
- [Maintainer checks](#maintainer-checks)

## Build and test

Use macOS or Linux with the [runtime prerequisites](../README.md#requirements), Deno 2.9.5 (pinned in [`.deno-version`](../.deno-version)), and Rust/Cargo. The commands below use rustup to select the compiler pinned in [daemon/rust-toolchain.toml](../daemon/rust-toolchain.toml). Personal Neovim configuration, language servers, and Nix are not required for the isolated suites.

A native linker and platform development files are also required: install Xcode Command Line Tools on macOS, or a C compiler/linker and standard development headers on Linux (for example, `build-essential` on Debian/Ubuntu). rustup does not install these system tools. Install StyLua separately to run the Lua formatting checks; rustfmt is included in the toolchain command below.

Clone the repository, then run these commands from its root:

```sh
rustup toolchain install 1.97.1 --profile minimal --component rustfmt
cargo +1.97.1 build --locked --manifest-path daemon/Cargo.toml
deno install --entrypoint scripts/*.ts tests/*.ts benchmarks/*.ts
deno task check
```

The executable is `daemon/target/debug/diffreel-daemon`. Local Cargo builds identify as `local` and work with an explicit daemon path.

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

This runs headless Lua tests, daemon shutdown, fixture checks, inline UI, UI/LSP integration, stability, exploratory regressions, and seeded stateful operation sequences. Each run records its executable and runtime versions in `environment.json`. It uses the TypeScript LSP server supplied in the repository. The `syntax-switch` case is excluded because it requires an installed Lua Tree-sitter parser; process-accounting tests run only on macOS. Rust unit tests are run separately by the command above.

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
| Cargo debug / release | `daemon/target/debug/diffreel-daemon` / `daemon/target/release/diffreel-daemon` |
| Nix | `result/bin/diffreel-daemon` |
| Plugin | Explicit `daemon` option, then `vim.g.diffreel_daemon`, then managed cache |
| Headless Lua tests | Pass `g:diffreel_daemon`; tests may also read `DIFFREEL_DAEMON` |
| Deno UI/shutdown tests | Set absolute `DIFFREEL_DAEMON` |
| Suite runner, stability, exploratory tests, benchmarks | Supply `--daemon` |

Building one executable does not update a configuration pointing at another. Lua changes need a fresh editor; Rust changes also need the configured executable rebuilt. A healthy worktree manager keeps its process after the last review closes.

## Choose checks by the change

Use the baseline and the applicable rows below. All Lua filenames are under `tests/`; run them using the same headless invocation and daemon environment as `tests/ui.lua` above.

| Changed behavior | Focused checks |
|---|---|
| Content, metadata, Git discovery | `unit.lua`, `repository.lua`, `content_cases.lua`, `repository_modes.lua`; Rust tests |
| Daemon lifecycle, retry, stale startup | `startup.lua`, `crash.lua`, `ui_restart.lua`, `daemon_shutdown.ts`; stability `worker-crash`, `git-failure` |
| Monitoring and comparison invalidation | `watcher.lua`, `regressions.lua`, `repository.lua`; stability `mixed-updates`, `multiple-comparisons`, `rename-reappear`, `ignore-change` |
| Explorer hierarchy, folding, path copies | `tree_actions.lua`, `tree_display_cache.lua`, `tree_clipboard.lua`, `tree_clipboard_command.lua`, `tree_ui.lua`; stability `tree-navigation`; exploratory `tree-type-change` |
| Commands, selection, tab/window lifecycle | `ui.lua`, `ui_edges.lua`, `ui_races.lua`, `exploration.lua`, `autocmd_lifecycle.lua`; stability `toggle`, `tree-navigation`, `rapid-selection`, `rapid-open-close`, `move-right-tab`, `move-clone-tab` |
| Comparison scopes, index, merge-base, preferred initial file | `options.lua`, `comparison_options.lua`, `initial_selection.lua`; Rust repository regressions, `repository.lua`, `watcher.lua`, `ui_restart.lua` |
| Explorer list/compaction/placement and single-file mode | `explorer_layout.lua`, `layout_options.lua`, `panel_ui.lua`, `path_popup.lua`, `file_mode.lua`, `navigation_edges.lua`; Rust pinned-file tests |
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
stylua --check lua plugin tests benchmarks scripts
cargo +1.97.1 fmt --check --manifest-path daemon/Cargo.toml
git diff --check
git diff --cached --check
```

StyLua uses [stylua.toml](../stylua.toml). Use `nix fmt -- flake.nix daemon/package.nix` when editing Nix files; that command rewrites them.

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

Regenerate the README image on macOS with ImageMagick, its built-in MSVG renderer, and the system Menlo font:

```sh
deno run --frozen -A scripts/capture-docs.ts \
  --daemon "$PWD/daemon/target/debug/diffreel-daemon" \
  --font /System/Library/Fonts/Menlo.ttc \
  --output .wadackel/qa/docs-capture
```

The script creates a deterministic sample Git repository, opens a minimal Neovim session, captures the real UI, and exports `review.png`. It records versions, font checksum, daemon identity, configuration, and raw captures alongside the PNG. It does not use your normal editor configuration. Menlo is not bundled; another monospaced font file can be supplied with `--font`, but its metrics can change the image. The reference image uses Menlo and the documented renderer.

Review the PNG for clipping, glyph alignment, readable diff colors, and agreement with the caption, then copy it into `docs/assets/review.png`. Keep raw captures in the ignored output directory. The helper verifies the scene before capture; it is not a replacement for the UI test suites.

## Optional Nix environment

On macOS, [flake.lock](../flake.lock) pins the daemon toolchain and dependencies:

```sh
nix build .#default
nix flake check
```

Select `result/bin/diffreel-daemon` explicitly in configuration and tests. Nix includes Git-tracked files and their working-tree edits; stage new build inputs before building so they are included. The package runs Rust tests during its build, but an already realized successful package may be reused. It does not run the Neovim or Deno suites.

## Maintainer checks

[Maintenance](maintenance.md) describes distribution checks, anonymous installation tests, and macOS performance measurement. These tasks are separate from the contributor build-and-test path.
