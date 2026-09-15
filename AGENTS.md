# Working on diffreel

diffreel reviews changing Git worktrees using native Neovim diff and a real working-tree buffer for LSP and unsaved edits. Rust owns repository work and monitoring; Lua owns the Neovim UI and installation.

## Start here

1. Inspect `git status --short --branch` and the relevant diff. Preserve existing staged and unstaged work; do not reset the repository to obtain a clean baseline.
2. Read [README.md](README.md), [the user guide](docs/user-guide.md), and [Neovim help](doc/diffreel.txt) for user-visible behavior and configuration.
3. Use [docs/development.md](docs/development.md) for setup, test selection, commands, and deployment checks.
4. Use [docs/maintenance.md](docs/maintenance.md) for distribution and benchmark work.
5. Read the relevant [architecture sections](docs/architecture.md) before changing state, buffers, protocol, or monitoring.

These files contain the context needed to work here. External notes, previous conversations, another checkout's virtual environment, and old QA directories are not prerequisites.

The GitHub repository is `wadackel/diffreel.nvim`, the plugin name is `diffreel.nvim`, and the Lua module is `diffreel`.

## Find the owning code

| Change | Start with |
|---|---|
| Commands, tabs, selection, comparison lifecycle, navigation | [lua/diffreel/init.lua](lua/diffreel/init.lua) |
| Keymap configuration and operations | [lua/diffreel/keymaps.lua](lua/diffreel/keymaps.lua) |
| Shared real-buffer mappings and options | [lua/diffreel/lease.lua](lua/diffreel/lease.lua) |
| Window styling, folds, option restoration | [lua/diffreel/presentation.lua](lua/diffreel/presentation.lua) |
| Explorer rows and display paths | [lua/diffreel/explorer.lua](lua/diffreel/explorer.lua) |
| Rust transport and daemon | [lua/diffreel/backend/rust.lua](lua/diffreel/backend/rust.lua), [daemon/src](daemon/src) |
| Daemon installation and distribution | [install.lua](lua/diffreel/install.lua), [distribution.lua](lua/diffreel/distribution.lua), [scripts](scripts), [.github/workflows/ci.yaml](.github/workflows/ci.yaml) |
| Content semantics and Git parsing | [content.lua](lua/diffreel/content.lua), [model.rs](daemon/src/model.rs) |
| UI observation and measurement | [tests/support.ts](tests/support.ts), [benchmarks](benchmarks) |

## Preserve these contracts

- Preserve unsaved real-buffer text across external writes, deletion, unsupported replacements, selection, and close. Dirty/conflict labels depend on both buffer and disk state.
- Keep fixed comparisons fixed across refresh and backend restart. HEAD-following views transition to a new resolved comparison separately.
- Guard asynchronous results with the applicable manager/session, comparison, selection sequence, and view lifetime checks. A closed view must not reappear.
- Remove the previous buffer from native diff before replacing a pane's buffer. Two visible diff windows do not prove that only two buffers participate.
- Restore only options and mappings still owned by diffreel. Ordinary windows and definition targets retain their behavior; cleanup continues after a restoration error.
- Keep Git responsible for status, attributes, ignore, and rename discovery. Unsupported content remains explicit rather than silently disappearing.
- Preserve the command/API distinction: argument-free `:Diffreel` toggles the current review tab; explicit revisions and `open()` create comparisons.

## Working rules

- Keep routine exploration, implementation, tests, and audit in the main session. Use a separate reviewer only for a concrete independent question, not merely because several files changed.
- For behavior changes, reproduce the expected behavior with an appropriate existing test or focused regression before fixing it. Documentation-only changes need command/link validation, not new product tests.
- Select checks from the development guide. Shared semantics require Rust and Neovim integration tests; Rust unit checks do not cover the Lua UI.
- Comments explain rejected alternatives or implementation traps. Do not narrate what code does, add `Why:` labels, or preserve conversation history in comments.
- Follow root StyLua settings and Rust formatting. Keep shared protocol/content changes consistent across the Rust daemon, Lua UI, installer and their tests.
- Use the `.yaml` extension for YAML files.
- Update the relevant documentation when behavior, boundaries, or commands change. Keep transient Git state and historical pass counts out of permanent instructions.
- Store local logs, fixtures, and captures under ignored `.wadackel/qa/`; record the command, backend, configuration, executable, outcome, and verification limits.
- Keep measurement evidence with its source and executable identities; do not present local smoke runs as performance claims.
- Test helpers prepend this checkout to `runtimepath`. That alone does not prove the user's installed configuration loads it; follow the deployment check for integration changes.
- Lua edits need a fresh Neovim session. Rust edits also need a rebuild of the executable actually configured. Ordinary plugin development does not require a dotfiles or nix-darwin rebuild.
- Stay within the requested repositories. Do not edit external editor configuration, commit, or publish merely to finish a documentation or implementation task.

## Language

- Write committed artifacts in English: code, identifiers, comments, documentation, commit messages, PR titles and bodies, and issue text. Unicode test fixtures keep the non-ASCII data they exercise.
- Conversational replies follow the user's own language setting; that setting never changes the language of a committed artifact.
