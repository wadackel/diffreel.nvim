# User guide

Start with the [README installation examples](../README.md#install). This guide covers day-to-day workflows and recovery; [`:help diffreel`](../doc/diffreel.txt) is the reference for exact commands, options, and Lua APIs.

- [Choose a comparison](#choose-a-comparison)
- [Limit the comparison](#limit-the-comparison) and [line counts](#line-counts)
- [Review a GitHub pull request](#review-a-github-pull-request)
- [Review one file](#review-one-file) and [explorer layout](#explorer-layout)
- [Navigate and edit](#navigate-and-edit)
- [Hunks and text objects](#hunks-and-text-objects)
- [Integrate with events](#integrate-with-events)
- [Tree navigation](#tree-navigation) and [path copying](#copy-paths)
- [Customize keymaps](#customize-keymaps) and [highlights](#customize-highlights)
- [Understand the review](#understand-the-review)
- [Supported content](#supported-content)
- [Installation and updates](#installation-and-updates)
- [Troubleshooting](#troubleshooting)

## Choose a comparison

Run these commands from a Git worktree:

| Command | Result |
|---|---|
| `:Diffreel` | Toggle the current review tab, or open HEAD against the worktree |
| `:Diffreel HEAD` | Open a new HEAD-following worktree review |
| `:Diffreel HEAD~1` | Compare the resolved previous commit with the worktree |
| `:Diffreel main worktree` | Compare the resolved `main` revision with the worktree |
| `:Diffreel HEAD~1 HEAD` | Compare two resolved revisions; both panes show revision content |
| `:Diffreel --staged` | Compare HEAD with the index; `--cached` is an alias |
| `:Diffreel --staged HEAD~1` | Compare a resolved revision with the index |
| `:Diffreel --unstaged` | Compare the index with the worktree |
| `:Diffreel main...` | Compare merge-base(main, HEAD) with the worktree |
| `:Diffreel main...feature` | Compare merge-base(main, feature) with the resolved feature revision |
| `:Diffreel --repo /path/to/repo --stat` | Open another repository with saved line counts enabled |

Revision expressions such as `HEAD~1`, branch names, and tags resolve once for a view. They remain fixed through refresh and daemon restart. A literal left `HEAD` with right `worktree` or index follows HEAD as commits change. This applies to argument-free `:Diffreel`, explicit `:Diffreel HEAD worktree`, `:Diffreel --staged`, and the Lua API. Merge-base comparisons always freeze their resolved commit endpoints, including across restart. Unrelated histories or multiple merge bases produce an explicit error.

To keep the current HEAD fixed, run `git rev-parse HEAD` in the repository, copy the resulting commit ID, and pass that ID to `:Diffreel` as its first argument. A new view and a fixed baseline are separate choices: explicit arguments always create a view, but literal `HEAD` against `worktree` still follows HEAD.

Each review has its own tab, comparison, and selected file. Argument-free `:Diffreel` closes the review in the current tab, including from an additional split. From an ordinary tab, it opens a HEAD-following review. The Lua `open()` API always creates a view.

Index panes show read-only snapshots of staged content; worktree panes retain normal editing and unsaved-buffer behavior. Index changes made by other tools are reconciled by monitoring, refresh, and redisplay. Use Git or a staging plugin to change the index. `:0` is the index endpoint in the Lua API and explicit revision arguments, for example `:Diffreel HEAD :0`.

The explorer describes the selected pair of endpoints. HEAD/worktree can be clean while the index differs; choose `--staged` or `--unstaged` to inspect those differences. Intent-to-add files appear as unstaged additions, while truly staged empty files appear in staged comparisons. Unresolved conflicts remain explicit limitations even when disk text matches HEAD.

### Review a GitHub pull request

From an existing local clone, open a PR by number or URL:

```vim
Diffreel --pr=123
Diffreel --pr https://github.com/owner/repository/pull/123 --stat
Diffreel --pr=123 -- src tests
Diffreel --pr=123 --file=src/main.lua
```

The PR feature requires GitHub CLI (`gh`) on PATH and authentication with access to the target repository. Run `gh auth login` beforehand when needed. Normal local comparisons do not require `gh`. PR acquisition uses GitHub authentication without changing your credential-helper configuration.

A number uses gh's default repository for the local clone, ignoring the `GH_REPO` environment override. A URL identifies the repository explicitly; it must correspond to a configured remote or that remote's GitHub-reported fork parent. HTTPS and ordinary SSH remote URLs are recognized. Use `--repo=<local path>` to select another existing clone. No repository is cloned automatically, and this feature is GitHub-specific.

Both panes contain read-only revision content. The comparison uses the PR's recorded base/head commits and their merge base, so the current branch, staged changes, working files and unsaved buffers stay intact. This also supports private repositories, fork PRs, and closed/merged PRs with retrievable historical commits. A merge result is not substituted for the original PR head. Missing historical objects or an unavailable/ambiguous merge base produce an error. If a shallow clone lacks history, deepen it manually and retry; diffreel does not unshallow it automatically.

The explorer identifies the PR number, title and state. `R` and `:DiffreelRefresh` fetch its latest state into the same view, retaining the selected path when present. Focus return and filesystem monitoring do not refetch a PR. Comparison creation and the initial file's contents are prepared before activation; acquisition or preparation failure leaves the previous comparison visible. Later file-navigation failures use the normal stopped-view behavior. A pending request ends when the view closes or a newer request supersedes it. Acquisition has a 120-second deadline and does not block other reviews served by the daemon.

The Lua equivalent is:

```lua
require("diffreel").open({
  root = "/path/to/local/clone",
  pr = 123,
  selected_file = "src/main.lua",
  explorer = { position = "bottom" },
})
```

`paths`, `exclude`, `file`, `selected_file`, `line_stats` and `explorer` remain available. Explicit `left`, `right`, `merge_base`, `untracked`, or staged/unstaged command options cannot be combined with `pr`. Configured untracked visibility does not affect a fixed PR comparison. The normal rule that `file` cannot be combined with explicit path filters still applies.

Fetched commits remain protected by snapshot refs under `refs/diffreel/pr/`. Opening or refreshing queries GitHub for the latest metadata while reusing available objects; a failed network request does not silently open stale cached data. There is no separate offline PR browser.

To remove the repository's unused PR cache:

```vim
DiffreelPRCacheClear
DiffreelPRCacheClear --repo=/path/to/local/clone
```

Close PR views and wait for acquisitions to finish in every editor sharing that Git repository first. Cleanup refuses while the cache is in use, including through linked worktrees. It deletes only dedicated snapshot/staging refs; it does not run Git GC. Normal branches, remote-tracking refs, Git configuration, index, working files and `FETCH_HEAD` are preserved by acquisition and cleanup. Internal fetch disables bundle, tag-pruning, submodule, maintenance and hook side effects.

Recovery after a daemon restart restores the saved commits and comparison before an explicitly requested refresh. If all backing processes have exited and cache cleanup plus Git GC has removed those objects, recovery reports that the PR must be reopened. It never substitutes other revisions for an unavailable saved snapshot.

### Limit the comparison

Put Git pathspecs after `--`. Exclusions can also be supplied with repeatable `--exclude=<glob>` options:

```vim
Diffreel -- src tests
Diffreel --exclude=**/*.lock --exclude=dist/** --untracked=no
Diffreel --selected-file=src/main.lua -- src
Diffreel -- src/a\ file.lua
```

Paths and exclusion globs are relative to the repository root. Neovim command escaping applies: escape a space with a backslash; shell quoting is not used. Git evaluates pathspec magic, including `:(literal)`, `:(glob)`, and `:(exclude)`. `exclude` entries become `:(exclude,glob)` pathspecs. For example, `**/*.lock` excludes lock files at every depth, while `dist/**` excludes content under the root's `dist` directory.

Set defaults in `setup()`, or override them for one view with `open()`:

```lua
require("diffreel").setup({
  paths = {},
  exclude = { "**/*.lock" },
  untracked = true,
  line_stats = false,
})

require("diffreel").open({
  paths = { "src" },
  exclude = {},
  untracked = false,
  selected_file = "src/main.lua",
})
```

Per-view arrays replace the configured arrays. These conditions remain fixed through refresh, HEAD changes, and restart. Separate scoped views can coexist. A rename crossing the boundary appears as an addition or deletion according to the included endpoint, following Git's pathspec behavior.

`--untracked=no` (or `--no-untracked`) suppresses discovery of new untracked paths. A previously tracked path that was deleted from the index and recreated on disk still participates when the compared baseline contains it. Git ignore rules remain effective. A selected unsaved buffer can remain as a retained draft after its path leaves the change list.

Attribute pathspecs such as `:(attr:review)` use current working-tree attributes. Their membership is re-evaluated on updates even between fixed commit endpoints; the commit content stays fixed.

By default, the invoking real file is selected if it belongs to the comparison; otherwise the first compared file is selected. `selected_file` and `--selected-file` accept a repository-relative or absolute path. An unmatched preference falls back to the first file. Use `selected_file = false` to always start with the first file. The preference is consumed once; refresh preserves subsequent selection.

Command completion offers options, Git refs, and paths in their argument positions. Inside a review tab it uses that review’s repository, including from the explorer and help popup; an explicit `--repo` takes precedence. Ref discovery runs asynchronously and is cached for one minute per repository. On the first attempt, refs may become available on the next completion. Completion does not prepare or start the daemon. `:Diffreel --help` opens the command reference without opening a review.

### Review one file

Use `:Diffreel --file` to compare the invoking real file, or the selected file of the current review. The selected-file fallback also works from that review’s help popup or an unnamed extra split. Use `:Diffreel --file=src/main.lua` to specify a literal repository-relative or absolute path. Unlike the initial selection preference, this pins the comparison to exactly one file, including unchanged, ignored, or currently missing files. Wildcards in the name are literal.

```lua
require("diffreel").open({ file = true })
require("diffreel").open({ left = "main...", file = "src/main.lua" })
```

This mode overrides configured path exclusions and untracked visibility. Explicit `paths` or `exclude` options cannot be combined with `file`. Supported unsaved real buffers still take precedence over saved text. `=` marks unchanged content; `∅` and a pane message identify a file absent from both endpoints. Creation followed by refresh or monitoring recovers that state. Unsupported content retains its limitation message. A literal file comparison does not follow a rename to another path.

The explorer starts hidden. Add `--explorer` or `explorer = { visible = true }` to show it. `--file` alone takes no value in the next argument; use `--file=<path>` for an explicit path. `selected_file` continues to be a preference for a normal multi-file review.

## Navigate and edit

These are the default Normal-mode bindings. They can be changed with [keymaps](#customize-keymaps).

| Key | Where | Action |
|---|---|---|
| Enter | Explorer | Select a file or toggle a directory |
| Tab / Shift-Tab | Explorer | Next / previous compared file, keeping explorer focus |
| Ctrl-f / Ctrl-b | Explorer | Scroll the diff while keeping explorer focus |
| Ctrl-t | Explorer | Open the file under the cursor in another tab, if it is a regular worktree file |
| Ctrl-h | Explorer | Close an open branch, or close its parent and move to it |
| `^` | Explorer | Move to the parent without changing its open state |
| `E` / `W` | Explorer | Recursively expand / collapse the target subtree |
| `gE` / `gW` | Explorer | Expand / collapse all branches |
| `yp` / `yP` / `yn` | Explorer | Copy relative path / absolute path / name |
| `K` | Explorer | Show the complete absolute path |
| `i` / `I` | Explorer | Toggle list/tree mode / directory compaction |
| `<Leader>b` | Review panes | Hide / show the explorer |
| `<Leader>e` | Explorer | Focus the right pane |
| `<Leader>e` | Diff panes | Focus the explorer |
| `]f` / `[f` | Diff panes | Next / previous compared file |
| `]c` / `[c` | Diff panes | Next / previous native hunk within this file |
| `gL` | Review panes | Cycle side-by-side, stacked, and inline |
| `]h` / `[h` | Diff panes | Next / previous hunk across files |
| `[H` / `]H` | Diff panes | First / last hunk in the file |
| `R` | Explorer | Refresh or retry a stopped review |
| `g?` | Review panes | Show active diffreel mappings for this pane |
| `q` | Review panes | Close the review tab |

The `<Leader>gD` toggle mapping comes from the README examples; it is not installed by `setup()` itself. Set your leader before configuring the plugin.

The `g?` popup reflects resolved leaders, aliases, custom callbacks, disabled mappings, and later replacements. It lists only mappings still owned by diffreel in the active pane. Close the popup with `q`, Esc, or `g?`; the review and its unsaved text remain open.

File navigation follows the explorer's file order, including files inside folded branches. It starts from the selected comparison file, accepts counts such as `2<Tab>` or `2]f`, reveals collapsed parent directories, and stops at the first or last file. Clicking into another explorer row without selecting it does not change the starting point for next/previous navigation. At a navigation boundary, the selected file is revealed again without reloading its content.

For supported worktree files, the right pane uses the same real buffer as ordinary editing windows. Your configured LSP can attach to it. Use your existing hover and definition mappings; a definition jump temporarily pauses the comparison in that pane. Return to the source buffer or select another file to resume it. Virtual revision buffers do not become LSP clients.

Closing a review preserves real buffers and their unsaved text. Closing, moving, or replacing one of its panes with ordinary Neovim commands releases that review; surviving file windows remain usable. `:DiffreelClose` and `:DiffreelRefresh` also work from extra splits in the review tab. Buffer mappings act only in diffreel's own panes.

### Hunks and text objects

`]h` / `[h` move through the current native diff and continue into the next or previous file in explorer order. Counts such as `3]h` count landed hunks. Files with only metadata changes or unsupported content are skipped. Navigation stops at either end without wrapping; switching files explicitly or leaving the review cancels a pending cross-file move. `[H` / `]H` jump to the first or last hunk of the current file.

In Visual and operator-pending modes, `ih` selects the changed real lines of the current native hunk. Use `vih`, `yih`, `dih`, or `cih`; editing operators require an editable pane. The text object uses unsaved buffer contents and Neovim's `diffopt`, including whitespace and linematch settings. It leaves unchanged lines and deletion-only filler anchors unselected. An empty operator text object cancels the operator and preserves registers.

A count includes up to that many nonempty hunks in the same file. For example, `2yih` yanks the current and next hunk as one linewise range, including any unchanged lines between them. Text objects never cross file boundaries. `[c` / `]c` keep their native or user-defined behavior in split views. In inline, their default diffreel bindings navigate native hunks through the hidden comparison; deleted decorations are never selected by `ih`.

### Diff layouts

Use `gL` in a review pane to cycle `side_by_side` → `stacked` → `inline`. Choose a layout directly with `:DiffreelLayout stacked`; argument-free `:DiffreelLayout` also cycles. New reviews accept `--layout=inline`, including with `--pr` and `--file`.

| Layout | Display |
|---|---|
| `side_by_side` | Left endpoint on the left, right endpoint on the right; default |
| `stacked` | Left endpoint above the right endpoint |
| `inline` | Right endpoint with removed old lines displayed as virtual lines |

```lua
require("diffreel").setup({ layout = "side_by_side" })
local view = require("diffreel").open({ layout = "inline" })
require("diffreel").set_layout(view, "stacked")
require("diffreel").cycle_layout(view)
```

Switching preserves selection, the real right buffer, unsaved text, Undo history, and configured LSP attachments. The Explorer remains independently configurable. Split proportions are remembered per layout and restored after editor resizing. Manual pane resizing sets the preferred proportion. Available screen space can constrain the actual sizes; expanding the editor restores the preferred proportion. This also works with a hidden explorer or numeric explorer dimensions. A pending file selection finishes in the requested layout. An accepted layout switch cancels pending cross-file hunk navigation.

Inline shows the same editable worktree buffer used by split views. PR, commit and index endpoints remain read-only. Removed lines are decorations scoped to this review window: cursor movement, search, copying and editing operate on the right buffer only. The ordinary window displaying that buffer does not receive the decorations. Deleted text retains its tab alignment, and its gutter follows the review window’s number and sign-column settings.

#### Inline compatibility and limits

Inline uses Neovim's experimental window-scoped namespace API (`nvim__ns_set` / `nvim__ns_get`), checked at runtime. `:checkhealth diffreel` reports availability with the current options. Inline requires `internal` in `diffopt` and supports Myers, minimal, patience and histogram algorithms, `iwhite`, `iwhiteall`, `iwhiteeol`, `iblank`, and native `linematch`. `icase`, a nonempty `diffexpr`, and `diffanchors` are unsupported. Split layouts retain Neovim's usual diff behavior.

Each inline side is limited to **1 MiB and 20,000 lines**, including unsaved edits. Increasing `max_bytes` does not raise these limits. Oversized text is never truncated. An unsupported request leaves the current split intact. If content or options become unsupported while inline is active, decorations are cleared and the review returns to its most recent split layout (initially `side_by_side`), preserving the buffer and draft.

Removed lines are grouped at the start of each coarse changed block, in old-file order. Native `linematch` may split that block into several navigation stops; the deleted decorations do not interleave at those refined stops. Hunk movement, `ih`, character highlighting and context folds still use the native comparison. `[c` / `]c` operate within the file; `]h` / `[h` can continue across files. Opening a context fold is retained across inline updates and layout switching.

If you disable default keymaps, bind `next_change` / `prev_change` to navigate within an inline file. These actions also work in split views; the automatic inline-only behavior applies to the default `[c` / `]c` keys. Explicitly assigning either key to `next_change` / `prev_change` makes that assignment active in every diff layout.

### Explorer layout

Press `i` in the explorer to switch between a tree and a sorted flat file list. The list shows full relative paths and ignores folding operations, while preserving folds for a return to tree mode. `I` toggles compaction of single-child directory chains. A compact row represents its deepest directory; parent navigation uses visible rows, and path/name operations refer to that deepest directory. Compaction stops at existing folds and paths that are themselves compared files.

When the cursor reaches a clipped row, a borderless, single-line overlay shows
its unshortened name immediately. It retains indentation, icons, colors, status
and optional line counts. Tree mode expands the name, compact mode the joined
directory names, and list mode the relative path. Focus stays in the explorer,
so you can keep moving between rows without dismissing it.

The overlay extends over the adjacent diff pane without resizing it. It stays
aligned with the original row even at the screen's right edge; text beyond
that edge remains clipped. It does not wrap or shift left. Moving to an
unclipped row or leaving the explorer closes it. Horizontal scrolling or
enabling `wrap` suppresses it. Use `K` for the complete absolute path, or set
`explorer.full_name = false` to disable automatic expansion. This boolean works
in `setup()`, `open()`, and `set_explorer()`.

Press `<Leader>b` in a review pane to hide or show the explorer. `<Leader>e` from a diff pane also shows a hidden explorer before focusing it. Configure defaults or update an existing view:

```lua
require("diffreel").setup({
  explorer = { mode = "tree", compact = false, visible = true, position = "left", height = 10 },
})
local view = require("diffreel").get_current()
require("diffreel").set_explorer(view, { position = "bottom", height = 8, mode = "list" })
```

Positions are `left`, `right`, `top`, and `bottom`; `width` controls a vertical panel and `height` a horizontal panel. The existing top-level `width` remains the default vertical width. Hiding and repositioning preserve the selected file, pane buffers, drafts, folds, and scroll position. Layout changes do not request Git data. Native closure of a managed pane still releases a broken review; use the toggle to hide intentionally.

Both dimensions accept a positive integer or a synchronous function that returns one:

```lua
require("diffreel").setup({
  explorer = {
    width = function(ctx) return math.max(22, math.floor(ctx.columns * 0.25)) end,
    height = function(ctx) return math.max(1, math.floor(ctx.lines * 0.25)) end,
  },
})
```

`ctx.columns` and `ctx.lines` are the full editor dimensions in columns and rows. Return an integer from 1 to 2147483647; fractional values, percentage strings, and `nil` are invalid. Keep callbacks limited to calculations without changing editor state. Setup stores functions without calling them. Per-open settings and `set_explorer()` accept the same functions.

Only the dimension used by the current position is evaluated: when first shown, when the position changes, when that dimension is explicitly supplied to `set_explorer()`, and when the editor resizes. Reapplying the same function recalculates its result. Changing list/tree mode, compaction, or only the other dimension does not invoke it.

Without either width setting, the automatic width is 20% of the editor width rounded down and clamped to 22–35 columns; it also follows editor resizing. The default height is 10 rows. Calculated sizes remain constrained by available screen space. After a resize, an inactive review applies its new size when its tab is entered, and a hidden explorer applies it when shown.

Native manual resizing is retained across hide/show until the relevant size setting changes or the editor resizes. An intervening resize expires that manual adjustment even if the editor returns to its previous dimensions while the explorer is hidden. Numeric sizes retain their manual adjustments and are not reset to the configured number on editor resize; use `set_explorer(nil, { width = 40 })` to explicitly restore a width.

An invalid callback result or error prevents an explicit open/update before it changes the layout. Initially hidden explorers defer evaluation until shown. During automatic resizing, a failed calculation keeps the current layout usable, reports one notification per dimension until a successful calculation, and retries on later resizing or explicit updates. Diff panes retain their preferred split proportion through editor resizing even when the explorer size calculation fails, subject to native space limits.

Command equivalents are `--list`, `--tree`, `--compact`, `--no-compact`, `--explorer`, `--no-explorer`, and `--explorer-position=bottom`. The position also accepts its value as the next argument. Per-open `explorer` fields override the configured defaults, and live updates are confined to the supplied view.

### Status icons

The explorer places a colored status icon at the right edge of each file row, after saved line counts when enabled. The four Git change icons follow eda.nvim and require a Nerd Font. Font support is not detected automatically; status icons work independently of `nvim-web-devicons`.

| `explorer.status_icons` key | Default |
|---|---|
| `added` | `` |
| `modified` | `` |
| `deleted` | `` |
| `renamed` | `` |
| `metadata` | `~` |
| `limited` | `!` |
| `typechange` | `T` |
| `unchanged` | `=` |
| `missing` | `∅` |
| `buffer_only` | `*` |
| `unknown` | `?` |

A buffer-only row uses `buffer_only` instead of its Git status icon. These symbols describe the comparison's existing states; colors use the corresponding `DiffreelExplorer…Marker` highlight groups.

For ordinary symbols without a Nerd Font:

```lua
require("diffreel").setup({
  explorer = {
    status_icons = { added = "+", modified = "~", deleted = "-", renamed = ">" },
  },
})
```

`setup()` merges each supplied key into the current defaults. `open({ explorer = { status_icons = … } })` overrides those defaults for a new comparison, and `set_explorer(view, { status_icons = … })` updates an existing view immediately. Omitted keys retain their values; input tables are copied. Later `setup()` calls leave existing views' symbols unchanged.

Each value must be a nonempty string without control characters. Unknown keys and invalid values are rejected before changing configuration or a view. Multiple-character and wide symbols are supported; their display width is reserved when shortening file names and aligning the status column.

### Tree navigation

Tree operations use the cursor row, independently of the file displayed in the diff. They keep explorer focus and preserve the comparison, prepared buffers, and unsaved text. Folding does not request new Git status or file content.

The controls follow eda.nvim's tree keys:

- **Ctrl-h** closes an open branch while remembering its descendants' open states. On an ordinary file or an already closed branch, it closes the parent and moves to that parent.
- **`^`** moves to the parent without folding it. Parent navigation stops at the worktree boundary; it never changes the comparison root.
- **`E` / `W`** recursively open or close a branch and all of its descendants. On an ordinary file, they target its parent. `W` moves the cursor to the collapsed target. For a top-level file, the implicit root is the target, so these operate on the whole tree and leave that file's cursor in place.
- **`gE` / `gW`** open or close the whole comparison tree. If folding hides the cursor row, the cursor moves to its nearest visible ancestor, or the first tree row if no ancestor remains.

Directories start expanded. Recursive operations cover all depths of the known comparison tree, including hidden children; they do not scan additional filesystem directories. There is no expansion-depth option. Headers and empty rows are ignored by cursor-dependent operations; whole-tree operations still work when the tree contains entries. These actions ignore counts.

Refresh preserves the cursor's column and scroll position when its row remains visible, including a cursor placed in the header or footer. Resizing the explorer updates label clipping and status alignment. Long directory names are shortened like file names; backslashes and control characters are escaped for display so literal escape sequences remain distinguishable.

Existing paths retain their fold state through refresh, HEAD changes, and delayed content reads. Removed branch state is discarded, and newly appearing directories start expanded. An automatic change of the selected comparison file does not reopen folders or move the tree cursor to that file. Explicit file selection and next/previous navigation reveal their target instead. Each review keeps its own fold state.

A comparison path can be a file on one side while also having descendant entries from the other side. Such rows show an expansion indicator and support the tree controls, while Enter still selects the file comparison. Folding never removes those entries from the comparison.

### Copy paths

Press `K` on a file or directory row to inspect the full absolute path in a wrapping popup. Backslashes and control characters are escaped. This requires no clipboard provider and works for deleted files. Close it with `K`, `q`, or Esc.

Use `yp` for the worktree-relative path, `yP` for the absolute path, or `yn` for the name of the cursor row. Directory rows and file rows are supported, including deleted, limited, renamed, and retained unsaved entries. The original path is copied, not the shortened or escaped display label.

Copies go to the `+` register as characterwise text, without added quotes, escaping, or a trailing directory separator. Absolute paths are joined to the worktree root without resolving symlink targets or checking whether the path still exists. On a header, error line, or empty row, these actions do nothing.

Neovim must have a working clipboard provider. Unavailable providers and copy errors are reported; diffreel does not silently fall back to another register. Provider command failures use Neovim's own diagnostics. See `:help provider-clipboard` for provider configuration. Copy actions leave the cursor, focus, and current diff unchanged and ignore counts.

## Customize keymaps

`setup()` accepts Normal-mode `explorer` and `diff` sections, plus `diff_visual` (Visual, `x`) and `diff_operator` (operator-pending, `o`) sections. The `diff` section applies to both diff panes, including a supported real working-tree buffer. Mappings run only in their review's own panes; ordinary windows and definition targets keep their normal behavior.

```lua
require("diffreel").setup({
  keymaps = {
    defaults = true,
    explorer = {
      q = false,
      ["<Esc>"] = "close",
      ["]n"] = "next_file",
    },
    diff = {
      ["<Leader>r"] = function(ctx)
        require("diffreel").refresh(ctx.view)
        vim.notify("Refresh requested")
      end,
    },
  },
})
```

With lazy.nvim, supply this table as `opts.keymaps`. The default is `defaults = true`: unspecified keys keep their built-in assignments. `false` disables a diffreel binding without deleting a user's existing mapping or a Neovim built-in operation. Adding another key does not remove the old one; use `false` on the old key if you want to replace it.

To use only your own assignments:

```lua
require("diffreel").setup({
  keymaps = {
    defaults = false,
    explorer = { ["<Esc>"] = "close", j = "next_file", k = "prev_file" },
    diff = { ["<Esc>"] = "close" },
  },
})
```

### Built-in operations

| Operation | Scope | Effect |
|---|---|---|
| `close` | Either | Close this review |
| `refresh` | Either | Reconcile or retry this review |
| `show_help` | Either | Show this pane's active diffreel mappings |
| `toggle_explorer` | Either | Hide or show the explorer |
| `cycle_layout` | Either | Cycle the three diff layouts |
| `layout_side_by_side` / `layout_stacked` / `layout_inline` | Either | Select a diff layout |
| `next_change` / `prev_change` | Either | Move by the count within the current file |
| `toggle_listing` / `toggle_compact` | Either | Toggle list/tree mode / compact directory chains |
| `show_path` | Explorer | Display the cursor row’s full absolute path |
| `next_hunk` / `prev_hunk` | Either | Move by the count across files; explorer mappings use the right pane |
| `first_hunk` / `last_hunk` | Either | First / last hunk in the current file |
| `next_file` / `prev_file` | Either | Move by the supplied count; stop at either end |
| `focus_explorer` / `focus_right` | Either | Focus the explorer or right pane |
| `scroll_down` / `scroll_up` | Either | Scroll the right pane by a quarter of its height, keeping focus |
| `select_entry` | Explorer | Select the explorer cursor's file or toggle its directory |
| `edit_file` | Explorer | Open the cursor's regular worktree file in another tab |
| `collapse_node` | Explorer | Close a branch, or close and move to its parent |
| `parent` | Explorer | Move the cursor to the parent |
| `expand_recursive` / `collapse_recursive` | Explorer | Open / close the target subtree |
| `expand_all` / `collapse_all` | Explorer | Open / close the whole comparison tree |
| `yank_path` / `yank_path_absolute` / `yank_name` | Explorer | Copy relative path / absolute path / name |

The table above applies to Normal mode. `select_hunk` is the only named operation in `diff_visual` and `diff_operator`; both default to `ih`. File navigation, `next_change` / `prev_change`, cross-file hunk navigation, and `select_hunk` consume counts. Other operations ignore counts. The default `]c` / `[c` bindings act only in inline; split and ordinary windows retain their native or user mappings. Your global `:Diffreel` toggle mapping is independent of these defaults.

### Custom callbacks and key notation

A function value receives `{ view = ..., count = ..., mode = ... }`; `mode` is `n`, `x`, or `o`. `view` is the opaque handle accepted by diffreel's [Lua API](../doc/diffreel.txt); `count` is `vim.v.count1`, which is 1 when no count is entered. Use normal Neovim APIs for other editor state. Callback return values are ignored: these are actions, not expression mappings. An error is reported without automatically closing the review.

Each scope supports its named operations or Lua functions. Custom Visual/operator callbacks must implement their own selection and cancellation semantics. Select mode is not intercepted. RHS command strings and mapping options such as `expr` or `remap` are not accepted. Put custom commands inside a function.

Neovim key notation is supported, including `<Leader>`, `<LocalLeader>`, and `<lt>` for a literal `<`. Leaders are resolved when the configuration is applied, so set them before `setup()`. Changing a leader variable alone does not move existing diffreel bindings. Prefix chords use Neovim's normal timeout handling; diffreel does not force `nowait`.

Neovim's distinctions between keys such as `<Tab>` and `<C-i>` are preserved; whether your terminal can send them distinctly depends on its keyboard protocol. Duplicate native key identities in one section, unknown operations, unsupported scopes, invalid or overlong keys, and the reserved `<Plug>(Diffreel...)` namespace are rejected during `setup()`.

### Reconfigure or reset

Close all review tabs before applying a different effective keymap configuration. A pending review counts as open, and closing must finish releasing its buffer mappings before a new policy can be applied. This keeps mappings consistent when several reviews share one real buffer. You can close reviews individually or call `require("diffreel").shutdown()` to close them all while preserving real buffers.

Omitting `keymaps` in a later `setup()` retains the current bindings and resolved leaders. Supplying a `keymaps` table replaces the override specification and resolves it from the defaults; it does not merge with an earlier keymaps table. To restore all defaults after closing the reviews, call:

```lua
require("diffreel").setup({ keymaps = {} })
```

Identical effective mappings are accepted while a review is open. Custom callbacks must be the same function references for that comparison. A rejected setup leaves the existing configuration and mappings unchanged. Other `setup()` fields retain their normal merge behavior.

## Integrate with events

User events expose the review lifecycle without polling: `DiffreelOpen`, `DiffreelEnter`, `DiffreelLeave`, `DiffreelDiffBufRead`, `DiffreelFileSelect`, `DiffreelLayoutChanged`, `DiffreelReady`, and `DiffreelClose`. Register handlers before opening a review.

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "DiffreelFileSelect",
  callback = function(event)
    local view = require("diffreel").get_view(event.data.view_id)
    if view and event.data.path then
      vim.notify("Reviewing " .. event.data.path)
    end
  end,
})
```

`Open` announces the prepared layout; backend/content preparation follows asynchronously. A successful selection emits `DiffBufRead` for each prepared side, then `FileSelect` when the selected path or comparison changes, then `Ready` when updating has finished. `Ready` can repeat and precedes the attached UI's next flush. Enter/leave refer to the review tab, not movement between panes. Close is emitted once after cleanup; `get_view()` then returns nil.

Event data includes `view_id`, `root`, and the current `path`, `comparison_id`, and `generation` when available. Buffer events also include `bufnr`, `side`, `visible`, and `layout`; `winid` is present only for a visible pane, so inline left-side events omit it. File-selection events include `previous_path`. Layout events include effective `explorer` options and, for a diff-layout change, `layout` and `previous_layout`. Inline `Ready` waits for the current decoration cache, including after a layout switch. Hooks may close a view or select another file, so later work checks whether the originating selection still exists. See [`:help diffreel-events`](../doc/diffreel.txt) for timing and recovery details.

## Customize highlights

Use `on_highlight` to customize diffreel's UI. It receives a fresh table of effective definitions, keyed by full highlight group names. Change entries in place; the return value is ignored. Assign a replacement definition to change a link into attributes:

```lua
require("diffreel").setup({
  on_highlight = function(groups)
    groups.DiffreelExplorerDirectoryName = { fg = "#89b4fa", bold = true }
    groups.DiffreelExplorerDirectoryIcon = { link = "Special" }
    groups.DiffreelExplorerAddedName = { link = "DiffreelExplorerAdded" }
    groups.DiffreelExplorerAddedMarker = { fg = "#a6e3a1" }
    groups.DiffreelExplorerStatsAdd = { fg = "#a6e3a1" }
    groups.DiffreelHelpKey = { bold = true }
    groups.DiffreelLineAdd = { bg = "#203040" }
    groups.DiffreelTextAdd = { bg = "#305060" }
  end,
})
```

With lazy.nvim, put `on_highlight` inside `opts`. Definitions use `nvim_set_hl()` attributes, including `fg`, `bg`, `bold`, `italic`, and `link`. A `link` takes precedence over other attributes in that definition; replace the table or remove `link` before setting individual colors. `{}` clears a group's attributes. Removing an entry with `nil` makes no override for that application. Only documented groups are accepted; `default` and `force` are managed by diffreel.

The priority is explicit callback changes, then existing colorscheme/user definitions, then diffreel defaults. Unchanged entries retain external customization. The callback runs on every `setup()` and `ColorScheme`, with fresh definitions and current theme-derived diff colors. Make the callback synchronous and modify only its supplied table. Invalid configuration fails before publishing colors or configuration. If the callback fails during a colorscheme change, diffreel reports the error and applies the theme/default definitions without that callback; the configured callback is retried on the next application.

A later `setup()` keeps the callback when `on_highlight` is omitted. Use `require("diffreel").setup({ on_highlight = false })` to disable it and restore the underlying theme/default definitions. Diffreel restores only definitions still equal to those it last installed, preserving later external changes. Already open views receive the changes; hidden explorers update when shown.

Standard calls such as `vim.api.nvim_set_hl(0, "DiffreelLineAdd", { bg = "#203040" })` also work. The callback reasserts its explicit definitions on the next setup or colorscheme change. For persistent customization across `:highlight clear`, use the callback or your colorscheme's own definitions.

Names, icons, status markers, line counts, selection, headers, messages, diff decorations and popup elements have separate groups. `DiffreelExplorerAdded`, `Modified`, `Deleted`, `Renamed`, `Metadata`, `TypeChange`, `Limited`, `Missing`, `Unchanged`, `BufferOnly`, and `Unknown` each have `Name`, `Icon`, and `Marker` groups. Names retain ordinary text colors by default; markers link to their status base. A buffer-only row uses the `BufferOnly` family. Directory arrows use `DiffreelExplorerDirectoryIcon`, including file/directory collision branches.

File icons retain `nvim-web-devicons` colors by default. Define `DiffreelExplorerFileIcon` to override all file icon colors, or a status-specific `Icon` group for that status. An explicit definition anywhere along the icon's link chain takes precedence over the provider, including an empty `{}` definition. Use the callback to clear an already-empty group such as `DiffreelExplorerFileIcon`: an identical direct `nvim_set_hl()` write cannot be distinguished from the installed default. After changing icon groups directly with `nvim_set_hl()`, call `require("diffreel").setup()` to update cached icon routing. This also works without devicons, but does not add icon glyphs when no provider supplies them.

Groups such as `DiffreelSelected`, `DiffreelAdded`, and `DiffreelDim` serve as default link targets. Split, stacked and inline layouts share line/text diff groups; `DiffreelInlineDeleteNumber` styles the virtual deleted-line number separately. Window chrome groups preserve explicit existing `winhighlight` mappings such as `Normal:MyNormal`; that window mapping takes precedence over the default mapping. Map the window explicitly to a diffreel group if desired. Standard `DiffAdd` and other global native groups are never changed.

See `:help diffreel-highlight-groups` for every public group and its default.

## Understand the review

The pane headers emphasize the file name, dim its parent directories, and identify a revision, the index, or the working-tree buffer. Unsaved buffers use the modification color. Ordinary LF text needs no format label; CRLF, BOM, missing final newlines, and content limitations remain explicit.

The explorer header shows the selected file's position, such as `2 / 12 files`, in the current tree or list order. A slim marker and a background highlight identify the selected file independently of the explorer cursor. HEAD-following reviews show `HEAD` in the explorer comparison; the revision pane retains the resolved commit ID.

Neovim supplies diff alignment, hunk navigation, and synchronized folds. The old pane uses deletion colors and the new pane uses addition colors. Line backgrounds blend with the current theme, while character-level changes use stronger colors. The explorer and pane headers share a subtle background. Transparent themes keep their native window backgrounds.

In side-by-side and stacked layouts, filler rows align additions and deletions with the opposite pane. Their characters follow Neovim's `fillchars.diff` setting and use the subdued `DiffreelFiller` highlight. To display diagonal lines, add this to your Neovim configuration before opening a review:

```lua
vim.opt.fillchars:append({ diff = "╱" })
```

An explicit space keeps filler rows blank; when the character is unspecified, Neovim uses its default. Review windows hide end-of-buffer characters. Other fill characters remain intact, and cleanup restores settings still owned by diffreel.

The explorer uses these comparison markers:

| Marker | Meaning |
|---|---|
| `A` / `M` / `D` | Added / modified / deleted |
| `R` | Renamed |
| `T` | File type changed |
| `~` | Metadata changed |
| `!` | Content has a reported limitation |
| `*` | An unsaved buffer retained after its path leaves the Git change list |

These markers describe the comparison; the selected file's buffer and disk state are reported separately in the headers and explorer details.

### Line counts

Use `:Diffreel --stat`, `open({ line_stats = true })`, or `setup({ line_stats = true })` to show additions and deletions next to each file and a total in the explorer footer. Counts are off by default; `--no-stat` overrides an enabled default for one view.

Counts describe the saved endpoint contents, including the index snapshot when selected. They do not count unsaved drafts. They use a Myers line comparison; BOM, line endings, and final-newline differences participate. Neovim's `diffopt` settings do not change these counts, so a whitespace-ignoring display can differ from the totals. Empty and missing files both contribute zero lines; metadata-only changes contribute no changed lines.

Content appears before counting starts. Counts arrive in bounded batches and are cached for the comparison's current generation; file switching does not recompute them. `…` means pending, `bin` means binary, and `—` means unavailable. The selected file's reason appears below the tree. A total labeled `partial` omits pending or unavailable counts. A retained unsaved-only entry has no saved comparison count.

Unsupported content, stale disk reads, or a pair exceeding 4 MiB or 200,000 combined lines has unavailable counts. These statistics limits are separate from `max_bytes`. A statistics failure leaves the review usable; refresh retries counts against current saved content.

### Unsaved edits and external writes

When the file on disk changes, an unmodified real buffer can be updated for the review. A modified buffer keeps your text. The right header identifies it as unsaved, and the explorer indicates when it differs from disk. This indication is about buffer-versus-disk content, not a Git merge-conflict marker.

The draft remains available through external deletion, unsupported replacements, file selection, and closing the review. If the selected path disappears from Git's change list—for example, after a commit or ignore-rule change—diffreel retains the unsaved buffer as a `*` entry and compares it against the current resolved baseline and disk state.

Saving is an ordinary Neovim write and writes your buffer to disk. diffreel does not merge external edits into a draft or provide a discard command. The indication follows both text and buffer format options, including line endings, BOM, and the final newline.

### Updates, hidden tabs, and failures

Filesystem events are batched over 100 ms, with a maximum batching wait of 250 ms. Git work and rendering take additional time. Visible worktree, index, and attribute-scoped comparisons also reconcile every 30 seconds by default to recover missed events; this is eventual reconciliation, not a filesystem snapshot taken at a single instant.

Hidden views do not run periodic Git reconciliation. Reopening a stale view reconciles its state; index views also reconcile on redisplay with watching disabled. Fixed revision pairs need worktree monitoring only for attribute pathspec membership. `R` or `:DiffreelRefresh` requests a full refresh; returning focus to Neovim also refreshes visible mutable comparisons.

If the daemon stops or a Git operation fails, the view reports the error and keeps prior prepared content visible. After correcting the problem, retry that view with `R` or `:DiffreelRefresh`. Other failed views are retried individually. Closing the last healthy view keeps its daemon available for another review; Neovim shutdown stops it.

## Supported content

| Content or repository feature | Behavior |
|---|---|
| UTF-8 text | Editable real worktree buffer; revision sides are virtual |
| UTF-8 BOM, LF/CRLF, final newline | Preserved as distinct metadata |
| Empty and missing files | Distinguished from each other |
| Executable mode changes | Reported even when text matches |
| Symlinks | Target text is compared without following the target |
| Binary, invalid UTF-8, mixed newlines, oversized content | Reported as limited content |
| Attribute transformations, conflicts, sparse entries | Reported explicitly rather than treated as ordinary editable text |
| Submodules | Metadata and limitation information, not an embedded submodule review |
| Linked worktrees and SHA-256 repositories | Supported |

Inline also has independent [display limits](#inline-compatibility-and-limits). The default content-read limit is **1 MiB per content side**. To raise it to 2 MiB, set `max_bytes = 2 * 1024 * 1024`. Larger limits can increase read, hashing, and diff costs. See the [configuration reference](../doc/diffreel.txt) or `:help diffreel-config` for all defaults.

Git remains responsible for discovery, ignore rules, attributes, and rename candidates. File paths containing spaces, tabs, newlines, and Unicode are handled independently of their escaped or shortened explorer labels. A file can replace a directory while the explorer still lists descendants from the other endpoint.

## Installation and updates

Plugin source and prebuilt daemons are public. Install using the HTTPS URLs in the README; no GitHub account or authentication is required. Daemon downloads use `curl` on Neovim's PATH. GitHub CLI is only needed for [PR review](#review-a-github-pull-request).

### Automatic downloads, pins, and rollback

The matching daemon is prepared asynchronously on first use. Run `:DiffreelInstall` to prepare it before opening a review. Each attempt has a 120-second timeout. Failure leaves an error that can be retried; it does not trigger a local compilation or select a different build.

Plugin releases use `vX.Y.Z` tags. Their matching daemon has been published and tested before the plugin tag is created. Daemon releases use `daemon-<build ID>`; this ID is derived from the installed Rust source and build inputs, so UI-only changes and version bumps can reuse a binary. Your plugin manager can pin a tag or commit, or install a shallow checkout: the installer does not need Git history. Restart Neovim after any plugin update or rollback.

The cache is under `stdpath("data")/diffreel/daemon/<build ID>/<target>`. New editor sessions check the executable against its installed verification record; incomplete or corrupt installations are downloaded again when automatic installation is enabled. Old IDs remain available for rollback and are not pruned automatically.

### Release versions and main

The README follows the latest versioned release. During 0.x development, breaking changes increase the minor version, while features and fixes increase the patch version. Read the [changelog](../CHANGELOG.md) before updating; following all releases can cross a breaking version boundary.

| Selection | lazy.nvim fields | vim.pack `version` |
|---|---|---|
| Latest release | `version = "*"` | `vim.version.range("*")` |
| Fixed release | `version = "v0.1.0"` | `"v0.1.0"` |
| Development branch | `version = false, branch = "main"` | `"main"` |

Use the development branch before the first versioned release is published. On main, Rust input changes can precede the matching daemon release briefly; wait for CI to finish and retry `:DiffreelInstall`.

After changing the selection, update through your plugin manager (`:Lazy update diffreel.nvim` or `:lua vim.pack.update({ "diffreel.nvim" })`) and restart Neovim. To roll back, select a previously published tag and update again. Keep the plugin manager's lockfile to reproduce exact installed commits. Daemon tags are internal download identifiers, not plugin versions.

### Offline use and custom binaries

Set `auto_install = false` to use only an existing verified cache or a custom daemon without automatic network access. An absent or invalid installation then produces an error. Manual `:DiffreelInstall` still permits a download.

Executable selection is:

1. `setup({ daemon = "/absolute/path/to/diffreel-daemon" })`.
2. `vim.g.diffreel_daemon`.
3. The verified managed cache for the installed plugin's build ID and platform.

A broken custom path produces an error instead of falling back. Custom binaries must support the current protocol. There is no implicit lookup in a Cargo build directory. Use the [development guide](development.md#build-and-test) to build locally and select the resulting executable explicitly.

`:DiffreelInstall` prepares the managed cache even when a custom path is configured. It does not change that configuration or replace a running daemon.

### Optional installation hooks

Hooks can prepare the daemon during plugin installation or updates. First use works without a hook. Each example starts a fresh headless Neovim process so updated source files are read independently of modules loaded in the current editor.

For lazy.nvim, add this field to the README's plugin specification:

```lua
build = function(plugin)
  local result = vim.system({
    vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE",
    "-l", plugin.dir .. "/scripts/install.lua",
  }, { text = true }):wait()
  assert(result.code == 0, result.stderr)
end,
```

For `vim.pack`, register this before `vim.pack.add`:

```lua
vim.api.nvim_create_autocmd("PackChanged", {
  callback = function(event)
    local data = event.data
    if data.spec.name == "diffreel.nvim" and (data.kind == "install" or data.kind == "update") then
      vim.system({
        vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE",
        "-l", data.path .. "/scripts/install.lua",
      }, { text = true }, vim.schedule_wrap(function(result)
        if result.code ~= 0 then
          vim.notify(result.stderr, vim.log.levels.ERROR)
        end
      end))
    end
  end,
})
```

The lazy.nvim hook waits for preparation during its build task. The `vim.pack` hook runs in the background and reports a failure through `vim.notify`. Neither changes Neovim's working directory.

## Troubleshooting

Start with `:checkhealth diffreel`. It reports local versions, the selected executable or build ID, cache health, and download-tool availability without accessing the network. It does not verify GitHub authentication or release availability.

| Symptom | Check | Recovery |
|---|---|---|
| `:Diffreel` is not a command | Plugin installation and lazy-loading specification | Use the README's `name`, `main`, and `cmd` fields, or the `vim.pack` example; restart Neovim |
| Current file is not in a Git repository | Current buffer and working directory | Open a file in the worktree or pass `root` to the Lua API |
| Release unavailable (HTTP error) | Release assets and CI for the installed commit | Wait for CI to finish, then retry `:DiffreelInstall` |
| curl is required | `curl` on Neovim's PATH | Install curl, or use a prepared offline/custom binary |
| Download times out or cannot connect | Network access from Neovim's environment | Restore connectivity and run `:DiffreelInstall`, or use a prepared offline/custom binary |
| Cache checksum or executable error | `:checkhealth diffreel` and `auto_install` | Run `:DiffreelInstall` for a corrupt managed cache; rebuild or correct an explicit custom path |
| Protocol/build ID/target mismatch | Plugin version and selected executable | Restart after updating; rebuild a custom daemon or prepare the matching managed binary |
| External edits are not visible yet | `watch`, current tab visibility, and the review's error message | Press `R`; check Git errors if refresh fails. Periodic reconciliation recovers missed events |
| Right pane shows a definition target | Navigation state | Return to the source buffer or select a file in the explorer |
| LSP is unavailable | Your language server configuration for a regular buffer | Configure the server normally; revision and limited-content buffers do not provide ordinary file editing |
| A file is marked limited | The displayed reason and content limit | Check the supported-content table; use a suitable external tool for unsupported content |

If a problem persists, follow the [bug-report checklist](../CONTRIBUTING.md#report-a-bug). Include a minimal reproduction and relevant diagnostics, with private paths, repository content, and credentials removed.
