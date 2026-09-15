# Contributing to diffreel

Bug reports, documentation improvements, and focused code changes help make diffreel easier to use and maintain. Start with the [user guide](docs/user-guide.md) to understand the review workflow and its boundaries.

## Report a bug

Search existing [issues](https://github.com/wadackel/diffreel.nvim/issues) first. For a new report, include:

- What you expected, what happened, and the exact commands or keys that reproduce it.
- Plugin commit, Neovim and Git versions, operating system, and CPU architecture.
- Relevant `setup()` options and whether you use an automatically downloaded or custom daemon.
- Relevant output from `:checkhealth diffreel` and the error displayed in the review.
- A small repository or shell recipe that reproduces the problem, preferably with a minimal Neovim configuration.

For a draft or refresh issue, describe which edits were unsaved, which were written by another process, the comparison revisions, and whether the review was visible. For an installation issue, distinguish failure to clone the plugin from failure to download the daemon.

Remove tokens, private repository content, and identifying paths before sharing logs or captures. Report what you observed without discarding an unsaved buffer just to simplify the reproduction. The [troubleshooting guide](docs/user-guide.md#troubleshooting) covers common recovery steps.

## Propose a feature

Describe the workflow you want to improve, an example of the desired interaction, and any existing workaround. diffreel focuses on reviewing changing worktrees with native Neovim editing. Staging, discard, merge resolution, and history browsing are outside its current feature set.

For changes that introduce a new workflow or alter public behavior, discuss the proposal in an issue before investing in a large implementation. Small fixes and documentation corrections can be proposed directly in a pull request.

## Develop a change

1. Follow [build and test](docs/development.md#build-and-test): enter `nix develop`, then use `just check`, `just build`, and `just test`. A [non-Nix setup](docs/development.md#without-nix) is available, including for Intel Macs.
2. Read the relevant [architecture contracts](docs/architecture.md) before changing asynchronous state, monitoring, buffers, or protocol behavior.
3. For a behavior change, reproduce the expected behavior with an existing test or a focused regression before implementing the fix.
4. Run the [checks relevant to the change](docs/development.md#choose-checks-by-the-change), and update user documentation when behavior changes.
5. Open a pull request that explains the problem, resulting behavior, and verification performed. Include any prerequisite or platform limits on that verification.

Keep changes focused. Use English for documentation, messages, and explanations. Unicode fixtures should retain the data needed to exercise non-ASCII paths and content.

Lua follows the repository's StyLua configuration; Rust follows rustfmt. Comments should explain an implementation trap or why an obvious alternative fails, rather than narrating the code or its revision history. Keep user text, normal-window behavior, and ownership-safe cleanup intact.

## Documentation changes

The README is the entry point, the user guide explains workflows, and `doc/diffreel.txt` is the command and API reference. Keep examples and defaults consistent across them. Maintainer internals belong in the architecture and development documentation.

Validate links, Lua examples, and help tags. Use a real Neovim capture when changing the introductory image; the [capture procedure](docs/development.md#documentation-and-captures) records its fixture and rendering environment. Prose-only edits do not require a full Rust or platform test run.

## License

diffreel's code and documentation are available under the [MIT license](LICENSE).
