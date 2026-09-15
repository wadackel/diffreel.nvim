import { within } from "../scripts/process.ts";
import { git, Nvim } from "./support.ts";
import {
  argumentsFor,
  assert,
  bytes,
  encoder,
  equal,
  exists,
  failure,
  includes,
  join,
  json,
  lines,
  mkdir,
  range,
  read,
  remove,
  resolve,
  run,
  sha256,
  temporary,
  wait,
  write,
} from "../scripts/lib.ts";
import { Random } from "./random.ts";

async function backendPids(n: Nvim) {
  const rows = lines((await run(["ps", "-axo", "pid,ppid,args"])).stdout).slice(
    1,
  );
  return rows.map((row) => row.trim().match(/^(\d+)\s+(\d+)\s+(.+)$/)).filter((
    match,
  ) =>
    match && Number(match[2]) === n.process.pid &&
    match[3].includes("diffreel-daemon")
  ).map((match) => Number(match![1]));
}
async function quit_application(n: Nvim, root: string, _out: string) {
  const children = await backendPids(n);
  assert(children.length, "Expected backend process was not found");
  await n.lua("vim.api.nvim_set_current_win(view.right_win)");
  await n.request("nvim_input", "gg0Cdraft discarded by explicit qa-bang\x1b");
  await n.wait("return vim.bo[view.right_buf].modified");
  try {
    await n.request("nvim_command", "qa!");
  } catch { /* Exit may precede the command reply. */ }
  assert((await within(n.process.status, 3, "Neovim quit timed out")).success);
  await wait(
    async () => {
      const states = new Map(
        lines((await run(["ps", "-axo", "pid=,stat="])).stdout).map((row) => {
          const [pid, state] = row.trim().split(/\s+/);
          return [Number(pid), state];
        }),
      );
      return children.every((pid) =>
        !states.has(pid) || states.get(pid)!.includes("Z")
      );
    },
    2,
    "Owned backend process survived editor exit",
  );
  assert(equal(read(join(root, "src/file_0.txt")), content(0, 1)));
}
async function worker_crash(n: Nvim, _root: string, _out: string) {
  const session = await n.lua("return view.manager.session_id"),
    pids = await backendPids(n);
  assert(pids.length === 1);
  Deno.kill(pids[0], "SIGKILL");
  await n.wait("return view.error", 3);
  assert(
    await n.lua(
      "return vim.api.nvim_buf_get_lines(view.right_buf,0,1,false)[1]",
    ) === "header 0",
  );
  await n.request("nvim_input", "R");
  await n.wait(
    "return view.ready and not view.error and not view.updating and view.manager.session_id~=" +
      JSON.stringify(session),
  );
}
export const RECONCILE_TIMEOUT = 35;

export function content(index: number | null, version: number) {
  return ([
    ...["header " + String(index), "value " + String(version)],
    ...(range(40)).map((line) => ("context " + String(line))),
  ].join("\n") + "\n");
}

export async function fixture(root: string) {
  mkdir(join(root, "src"));
  await git(root, "init", "-q");
  for (const i of range(3)) {
    write(join(root, "src/file_" + String(i) + ".txt"), content(i, 0));
  }
  await git(root, "add", ".");
  await git(root, "commit", "-qm", "baseline");
  for (const i of range(3)) {
    write(join(root, "src/file_" + String(i) + ".txt"), content(i, 1));
  }
}

export async function start(n: Nvim, backend: string, daemon: string) {
  await n.lua(
    "vim.g.mapleader=','; require('diffreel').setup({backend=select(1,...),daemon=select(2,...),watch=true})",
    backend,
    daemon,
  );
  await n.request("nvim_command", "Diffreel");
  await n.wait(
    "_G.view=require('diffreel').get_current();return view and view.ready and not view.updating",
  );
}

export async function steady(n: Nvim) {
  await n.wait(
    "return view.ready and not view.updating and not view.selection_pending",
  );
  assert(
    !(await n.lua("return view.error")),
    String(await n.lua("return view.error")),
  );
}

export async function select(n: Nvim, path: string) {
  await n.lua("_G.qa_selected_path=...", path);
  await n.lua(
    "vim.api.nvim_set_current_win(view.explorer_win);for i,row in ipairs(view.rows)do if row.path==... then vim.api.nvim_win_set_cursor(view.explorer_win,{i+3,0});break end end",
    path,
  );
  await n.request("nvim_input", "\r");
  await n.wait("return view.ready and view.selected_path==_G.qa_selected_path");
}

export async function dirty_delete(n: Nvim, root: string, out: string) {
  await n.lua(
    "vim.api.nvim_set_current_win(view.right_win);_G.source=view.right_buf",
  );
  await n.request("nvim_input", "gg0Cunsaved change\u001b");
  await n.wait("return vim.bo[source].modified");
  const before = await n.lua(
    "return vim.api.nvim_buf_get_lines(source,0,-1,false)",
  );
  remove(join(root, "src/file_0.txt"));
  await n.wait(
    "return view.by_path['src/file_0.txt'].right.exists==false and not view.updating",
  );
  await steady(n);
  assert(
    await n.lua("return view.right_buf==source"),
    String("External deletion hid the unsaved buffer"),
  );
  assert(
    await n.lua("return view.disk_conflict"),
    String("External deletion lost the conflict indication"),
  );
  assert(
    equal(
      await n.lua("return vim.api.nvim_buf_get_lines(source,0,-1,false)"),
      before,
    ),
  );
  await select(n, "src/file_1.txt");
  await select(n, "src/file_0.txt");
  assert(
    await n.lua("return view.right_buf==source and vim.bo[source].modified"),
  );
  n.capture(join(out, "screenshots"), "dirty-delete-retained");
  await n.lua("vim.api.nvim_set_current_win(view.right_win)");
  await n.request("nvim_command", "write");
  await n.wait("return not vim.bo[source].modified and not view.updating");
  assert(equal(lines(read(join(root, "src/file_0.txt"))), before));
}

export async function pane_close(
  n: Nvim,
  _root: string,
  _out: string,
  pane: string,
) {
  await n.lua(
    "_G.source=view.right_buf;vim.api.nvim_set_current_win(view[...])",
    pane,
  );
  await n.request("nvim_input", "\u0017c");
  await n.wait("return not view.alive", 2);
  assert(await n.lua("return vim.api.nvim_buf_is_valid(source)"));
  assert(
    equal(await n.lua('return vim.tbl_count(require("diffreel").views)'), 0),
  );
  assert(equal(await n.lua("return vim.v.errmsg"), ""));
}

export async function only_window(n: Nvim, _root: string, _out: string) {
  await n.lua(
    "vim.api.nvim_set_current_win(view.right_win);_G.source=view.right_buf",
  );
  await n.request("nvim_command", "only");
  await n.wait("return not view.alive", 2);
  assert(
    await n.lua(
      "return vim.api.nvim_get_current_buf()==source and not vim.wo.diff",
    ),
  );
  assert(equal(await n.lua("return vim.v.errmsg"), ""));
}

export async function rapid_selection(n: Nvim, _root: string, out: string) {
  await n.lua("vim.api.nvim_set_current_win(view.right_win)");
  await n.request("nvim_input", "2]f");
  await n.wait("return view.ready and view.selected_path=='src/file_2.txt'");
  await n.request("nvim_input", "2[f");
  await n.wait("return view.ready and view.selected_path=='src/file_0.txt'");
  await n.request("nvim_input", (("]f").repeat(50) + ("[f").repeat(50)) + "]f");
  await n.wait(
    "return view.ready and view.selected_path=='src/file_1.txt' and not view.selection_pending",
  );
  assert(
    equal(
      await n.lua(
        "return vim.api.nvim_buf_get_lines(view.right_buf,0,1,false)[1]",
      ),
      "header 1",
    ),
  );
  assert(
    equal(
      await n.lua(
        "return vim.api.nvim_win_call(view.right_win,function()return vim.fn.diff_hlID(1,1)end)",
      ),
      0,
    ),
  );
  await n.request("nvim_input", ",e" + ("R").repeat(15));
  await steady(n);
  assert(
    await n.lua("return vim.api.nvim_get_current_win()==view.explorer_win"),
  );
  assert(
    !(await n.lua("return vim.bo[view.right_buf].modified")),
    String("Refresh typeahead edited the source buffer"),
  );
  assert(equal(await n.lua("return vim.v.errmsg"), ""));
  n.capture(join(out, "screenshots"), "rapid-selection");
}

export async function tree_navigation(n: Nvim, root: string, out: string) {
  async function observe_input() {
    await n.lua(
      "vim.api.nvim_set_current_win(view.explorer_win);vim.keymap.set('n','<F12>',function()_G.tree_input_done=true end,{buffer=view.explorer_buf})",
    );
  }
  async function navigate(keys: string, index: number | null) {
    let expected;
    await n.lua("_G.tree_input_done=false");
    await n.request("nvim_input", keys + "<F12>");
    await n.wait(
      "return _G.tree_input_done and view.ready and not view.updating and not view.selection_pending",
    );
    assert(
      await n.lua("return vim.api.nvim_get_current_win()==view.explorer_win"),
      String("File navigation left the tree"),
    );
    const path = (index === null)
      ? null
      : ("src/file_" + String(index) + ".txt");
    assert(equal(await n.lua("return view.selected_path"), path));
    if ((index !== null)) {
      assert(
        equal(
          await n.lua(
            "return view.rows[vim.api.nvim_win_get_cursor(view.explorer_win)[1]-3].path",
          ),
          path,
        ),
      );
      assert(
        equal(
          await n.lua(
            "return vim.api.nvim_buf_get_lines(view.left_buf,0,-1,false)",
          ),
          lines(content(index, 0)),
        ),
      );
      expected = (equal(index, 0)) ? draft : lines(content(index, 1));
      assert(
        equal(
          await n.lua(
            "return vim.api.nvim_buf_get_lines(view.right_buf,0,-1,false)",
          ),
          expected,
        ),
      );
    }
  }
  await n.lua(
    "vim.api.nvim_set_current_win(view.right_win);_G.source=view.right_buf",
  );
  await n.request("nvim_input", "gg0Cdraft through tree navigation\u001b");
  await n.wait("return vim.bo[source].modified");
  const draft: string[] = await n.lua(
    "return vim.api.nvim_buf_get_lines(source,0,-1,false)",
  );
  await observe_input();
  for (
    const [keys, index] of [
      ["<Tab>", 1],
      ["<S-Tab>", 0],
      ["2<Tab>", 2],
      ["<Tab>", 2],
      ["2<S-Tab>", 0],
      ["<S-Tab>", 0],
    ] as const
  ) {
    await navigate(keys, index);
  }
  await n.lua(
    "vim.api.nvim_win_set_cursor(view.explorer_win,{#view.rows+3,0})",
  );
  await navigate("<Tab>", 1);
  await n.lua(
    "vim.api.nvim_win_set_cursor(view.explorer_win,{4,0});_G.tree_input_done=false",
  );
  await n.request("nvim_input", "<CR><F12>");
  await n.wait("return _G.tree_input_done and view.collapsed.src");
  await navigate("<Tab>", 2);
  assert(
    !(await n.lua("return view.collapsed.src")),
    String("Navigation did not reveal the collapsed target"),
  );
  await navigate((("<Tab>").repeat(50) + ("<S-Tab>").repeat(50)) + "<Tab>", 1);
  for (
    const buf
      of (await n.lua("return {view.left_buf,view.right_buf,view.empty_buf}"))
  ) {
    assert(
      await n.lua(
        "for _,m in ipairs(vim.api.nvim_buf_get_keymap(...,'n'))do if vim.keycode(m.lhs)==vim.keycode('<Tab>')or vim.keycode(m.lhs)==vim.keycode('<S-Tab>')then return false end end;return true",
        buf,
      ),
      String("Tree navigation mapping leaked into a diff pane"),
    );
  }
  n.capture(join(out, "screenshots"), "tree-navigation-draft");
  for (const index of [1, 2]) {
    write(join(root, "src/file_" + String(index) + ".txt"), content(index, 0));
  }
  await n.request("nvim_command", "DiffreelRefresh");
  await n.wait("return view.ready and not view.updating and #view.entries==1");
  await navigate("2<Tab>2<S-Tab>", 0);
  await n.request("nvim_command", "DiffreelClose");
  assert(await n.lua("return vim.bo[source].modified"));
  assert(
    equal(
      await n.lua("return vim.api.nvim_buf_get_lines(source,0,-1,false)"),
      draft,
    ),
  );
  assert(equal(read(join(root, "src/file_0.txt")), content(0, 1)));
  await n.request("nvim_command", "Diffreel HEAD HEAD");
  await n.wait(
    "_G.view=require('diffreel').get_current();return view and view.ready and not view.updating and #view.entries==0",
  );
  await observe_input();
  await navigate("<Tab><S-Tab>2<Tab>2<S-Tab>", null);
  assert(equal(await n.lua("return vim.v.errmsg"), ""));
}

export async function dirty_binary(n: Nvim, root: string, _out: string) {
  await n.lua(
    "vim.api.nvim_set_current_win(view.right_win);_G.source=view.right_buf",
  );
  await n.request("nvim_input", "gg0Cdraft against replaced file\u001b");
  await n.wait("return vim.bo[source].modified");
  const before = await n.lua(
    "return vim.api.nvim_buf_get_lines(source,0,-1,false)",
  );
  write(
    join(root, "src/file_0.txt"),
    new Uint8Array([
      0,
      98,
      105,
      110,
      97,
      114,
      121,
      32,
      114,
      101,
      112,
      108,
      97,
      99,
      101,
      109,
      101,
      110,
      116,
    ]),
  );
  await n.wait(
    "return view.by_path['src/file_0.txt'].right.kind=='limited' and not view.updating",
  );
  await steady(n);
  assert(await n.lua("return view.right_buf==source and view.disk_conflict"));
  assert(
    equal(
      await n.lua("return vim.api.nvim_buf_get_lines(source,0,-1,false)"),
      before,
    ),
  );
  await select(n, "src/file_1.txt");
  await select(n, "src/file_0.txt");
  assert(
    await n.lua("return view.right_buf==source and vim.bo[source].modified"),
  );
  await n.request("nvim_command", "DiffreelClose");
  assert(
    equal(
      bytes(join(root, "src/file_0.txt")),
      new Uint8Array([
        0,
        98,
        105,
        110,
        97,
        114,
        121,
        32,
        114,
        101,
        112,
        108,
        97,
        99,
        101,
        109,
        101,
        110,
        116,
      ]),
    ),
  );
  assert(
    equal(
      await n.lua("return vim.api.nvim_buf_get_lines(source,0,-1,false)"),
      before,
    ),
  );
}

export async function dirty_delete_close(n: Nvim, root: string, _out: string) {
  await n.lua(
    "vim.api.nvim_set_current_win(view.right_win);_G.source=view.right_buf",
  );
  await n.request("nvim_input", "gg0Cdraft kept through close\u001b");
  await n.wait("return vim.bo[source].modified");
  const before = await n.lua(
    "return vim.api.nvim_buf_get_lines(source,0,-1,false)",
  );
  remove(join(root, "src/file_0.txt"));
  await n.wait("return view.disk_conflict and not view.updating");
  await n.request("nvim_command", "DiffreelClose");
  assert(await n.lua("return vim.bo[source].modified"));
  assert(
    equal(
      await n.lua("return vim.api.nvim_buf_get_lines(source,0,-1,false)"),
      before,
    ),
  );
  assert(!(exists(join(root, "src/file_0.txt"))));
}

export async function edit_tab(n: Nvim, _root: string, _out: string) {
  await n.request("nvim_input", "\u0014");
  await n.wait("return vim.api.nvim_get_current_tabpage()~=view.tab");
  assert(await n.lua("return vim.api.nvim_get_current_buf()==view.right_buf"));
  assert(
    await n.lua(
      "return not vim.wo.diff and not vim.wo.winhighlight:find('Diffreel',1,true)",
    ),
  );
  await n.request("nvim_input", "gg0Cdraft in ordinary tab\u001b");
  await n.wait("return vim.bo[view.right_buf].modified");
  await n.lua(
    "vim.api.nvim_set_current_tabpage(view.tab);vim.api.nvim_set_current_win(view.explorer_win)",
  );
  await n.request("nvim_input", "q");
  await n.wait("return not view.alive");
  assert(await n.lua("return vim.bo[view.right_buf].modified"));
}

export async function move_clone(n: Nvim, _root: string, _out: string) {
  await n.lua(
    "vim.api.nvim_set_current_win(view.right_win);_G.source=view.right_buf",
  );
  await n.request("nvim_input", "\u0017v");
  await n.request("nvim_input", "\u0017T");
  await n.wait("return vim.api.nvim_get_current_tabpage()~=view.tab");
  assert(
    await n.lua("return view.alive"),
    String("Moving a non-review window destroyed the review"),
  );
  assert(
    await n.lua(
      "return vim.api.nvim_get_current_buf()==source and not vim.wo.diff and not vim.wo.winhighlight:find('Diffreel',1,true)",
    ),
    String("A copied window retained review presentation outside its tab"),
  );
}

export async function multiple_comparisons(n: Nvim, root: string, out: string) {
  const base = await git(root, "rev-parse", "HEAD");
  await n.lua("_G.headview=view");
  await n.request(
    "nvim_command",
    "Diffreel " + String(base) + " " + String(base),
  );
  await n.wait(
    "_G.fixed=require('diffreel').get_current();return fixed and fixed.ready",
  );
  await n.request("nvim_command", "Diffreel " + String(base));
  await n.wait(
    "_G.work=require('diffreel').get_current();return work and work.ready",
  );
  await git(root, "add", ".");
  await git(root, "commit", "-qm", "agent commit");
  const head = await git(root, "rev-parse", "HEAD");
  await n.lua("vim.api.nvim_set_current_tabpage(headview.tab)");
  await n.wait(
    "return headview.ready and not headview.updating and headview.comparison.left==" +
      JSON.stringify(head),
  );
  assert(equal(await n.lua("return #headview.entries"), 0));
  assert(equal(await n.lua("return #fixed.entries"), 0));
  assert(equal(await n.lua("return fixed.comparison.left"), base));
  await n.lua("vim.api.nvim_set_current_tabpage(work.tab)");
  write(join(root, "src/file_0.txt"), content(0, 2));
  await n.wait(
    "return work.ready and not work.updating and vim.api.nvim_buf_get_lines(work.right_buf,1,2,false)[1]=='value 2'",
  );
  assert(equal(await n.lua("return work.comparison.left"), base));
  assert(
    equal(
      await n.lua(
        "return vim.api.nvim_buf_get_lines(work.left_buf,1,2,false)[1]",
      ),
      "value 0",
    ),
  );
  await n.lua("vim.api.nvim_set_current_tabpage(headview.tab)");
  await n.wait(
    "return headview.ready and not headview.updating and #headview.entries==1",
  );
  assert(
    equal(
      await n.lua(
        "return vim.api.nvim_buf_get_lines(headview.left_buf,1,2,false)[1]",
      ),
      "value 1",
    ),
  );
  assert(
    equal(
      await n.lua(
        "return vim.api.nvim_buf_get_lines(headview.right_buf,1,2,false)[1]",
      ),
      "value 2",
    ),
  );
  assert(equal(await n.lua("return #fixed.entries"), 0));
  n.capture(join(out, "screenshots"), "independent-comparisons");
}

export async function dirty_matches_disk(n: Nvim, root: string, _out: string) {
  await n.lua(
    "vim.api.nvim_set_current_win(view.right_win);_G.source=view.right_buf",
  );
  await n.request("nvim_input", "gg0Csame new text\u001b");
  await n.wait("return vim.bo[source].modified");
  const draft =
    (await n.lua("return vim.api.nvim_buf_get_lines(source,0,-1,false)")).join(
      "\n",
    ) + "\n";
  write(join(root, "src/file_0.txt"), content(0, 2));
  await n.wait("return view.disk_conflict");
  write(join(root, "src/file_0.txt"), draft);
  const digest = await sha256(encoder.encode(draft));
  await n.wait(
    ("return view.by_path['src/file_0.txt'].right.content_id==" +
      JSON.stringify(digest)) + " and not view.updating",
  );
  await steady(n);
  assert(
    !(await n.lua("return view.disk_conflict")),
    String("Resolved disk conflict remains sticky"),
  );
  assert(await n.lua("return vim.bo[source].modified"));
}

export async function dirty_head(
  n: Nvim,
  root: string,
  out: string,
  navigation: boolean = false,
) {
  await n.lua(
    "_G.source=view.right_buf;vim.api.nvim_buf_set_lines(source,0,1,false,{'draft across commit'})",
  );
  const draft = await n.lua(
    "return vim.api.nvim_buf_get_lines(source,0,-1,false)",
  );
  if (navigation) {
    await n.lua(
      "vim.api.nvim_set_current_win(view.right_win);vim.cmd('edit target.txt')",
    );
    await n.wait("return view.navigation");
  }
  await git(root, "add", ".");
  await git(root, "commit", "-qm", "new head");
  const head = await git(root, "rev-parse", "HEAD");
  await n.request("nvim_command", "DiffreelRefresh");
  await n.wait(
    "return not view.updating and view.comparison.left==" +
      JSON.stringify(head),
  );
  if (navigation) {
    assert(
      equal(
        await n.lua("return vim.api.nvim_buf_get_name(0)"),
        String(join(root, "target.txt")),
      ),
    );
    await n.lua("vim.api.nvim_win_set_buf(view.right_win,source)");
  }
  await steady(n);
  assert(
    await n.lua("return view.right_buf==source and vim.bo[source].modified"),
    String("HEAD transition hid the draft"),
  );
  assert(
    equal(
      await n.lua("return vim.api.nvim_buf_get_lines(source,0,-1,false)"),
      draft,
    ),
  );
  assert(
    equal(
      await n.lua(
        "return vim.api.nvim_buf_get_lines(view.left_buf,0,-1,false)",
      ),
      lines(content(0, 1)),
    ),
    String("HEAD transition retained the previous baseline"),
  );
  assert(
    await n.lua(
      "return view.by_path['src/file_0.txt'].buffer_only and view.disk_conflict",
    ),
  );
  n.capture(join(out, "screenshots"), "draft-current-head");
  await n.request("nvim_command", "DiffreelClose");
  assert(await n.lua("return vim.bo[source].modified"));
  assert(
    equal(
      await n.lua("return vim.api.nvim_buf_get_lines(source,0,-1,false)"),
      draft,
    ),
  );
}

export async function dirty_baseline(n: Nvim, root: string, out: string) {
  await n.lua(
    "_G.source=view.right_buf;vim.api.nvim_buf_set_lines(source,0,1,false,{'draft against clean disk'})",
  );
  const disk = content(0, 0);
  write(join(root, "src/file_0.txt"), disk);
  await n.request("nvim_command", "DiffreelRefresh");
  await n.wait(
    "return view.ready and not view.updating and view.by_path['src/file_0.txt'].buffer_only",
  );
  await steady(n);
  assert(await n.lua("return view.right_buf==source and view.disk_conflict"));
  await n.lua("vim.api.nvim_buf_set_lines(source,0,-1,false,...)", lines(disk));
  await n.request("nvim_command", "DiffreelRefresh");
  await steady(n);
  assert(
    !(await n.lua("return view.disk_conflict")),
    String("Matching draft was compared against stale disk content"),
  );
  assert(
    await n.lua("return view.right_buf==source and vim.bo[source].modified"),
  );
  n.capture(join(out, "screenshots"), "draft-matches-clean-disk");
  await n.lua("vim.api.nvim_set_current_win(view.right_win)");
  await n.request("nvim_command", "write!");
  await n.request("nvim_command", "DiffreelRefresh");
  await n.wait(
    "return view.ready and not view.updating and not view.by_path['src/file_0.txt']",
  );
  assert(equal(read(join(root, "src/file_0.txt")), disk));
}

export async function dirty_ignored(n: Nvim, root: string, out: string) {
  write(join(root, "scratch.tmp"), "untracked\n");
  await n.request("nvim_command", "DiffreelRefresh");
  await n.wait("return view.by_path['scratch.tmp'] and not view.updating");
  await select(n, "scratch.tmp");
  await n.lua(
    "_G.source=view.right_buf;vim.api.nvim_buf_set_lines(source,0,-1,false,{'draft'})",
  );
  write(join(root, "scratch.tmp"), "draft\n");
  await n.request("nvim_command", "DiffreelRefresh");
  await steady(n);
  assert(!(await n.lua("return view.disk_conflict")));
  write(join(root, ".gitignore"), "scratch.tmp\n");
  await n.request("nvim_command", "DiffreelRefresh");
  await n.wait(
    "return view.ready and not view.updating and view.by_path['scratch.tmp'].buffer_only",
  );
  await steady(n);
  assert(
    !(await n.lua("return view.disk_conflict")),
    String("Ignored file was treated as absent despite matching the draft"),
  );
  assert(
    await n.lua("return view.right_buf==source and vim.bo[source].modified"),
  );
  assert(
    equal(await n.lua("return vim.api.nvim_buf_get_lines(source,0,-1,false)"), [
      "draft",
    ]),
  );
  n.capture(join(out, "screenshots"), "ignored-draft-matches-disk");
}

export async function save_undo(n: Nvim, root: string, _out: string) {
  await n.lua(
    "vim.api.nvim_set_current_win(view.right_win);_G.source=view.right_buf",
  );
  const before = await n.lua(
    "return vim.api.nvim_buf_get_lines(source,0,-1,false)",
  );
  await n.request("nvim_input", "gg0Csaved editor change\u001b");
  await n.wait("return vim.bo[source].modified");
  await n.request("nvim_command", "write");
  await n.wait("return not vim.bo[source].modified and not view.updating");
  const saved = read(join(root, "src/file_0.txt"));
  assert(saved.startsWith("saved editor change\n"));
  await n.request("nvim_input", "u");
  await n.wait("return vim.bo[source].modified");
  assert(
    equal(
      await n.lua("return vim.api.nvim_buf_get_lines(source,0,-1,false)"),
      before,
    ),
  );
  await n.request("nvim_command", "DiffreelClose");
  assert(await n.lua("return vim.bo[source].modified"));
  assert(equal(read(join(root, "src/file_0.txt")), saved));
}

export async function buffer_matches_disk(n: Nvim, root: string, _out: string) {
  await n.lua(
    "vim.api.nvim_set_current_win(view.right_win);_G.source=view.right_buf",
  );
  await n.request("nvim_input", "gg0Cunsaved draft\u001b");
  await n.wait("return vim.bo[source].modified");
  const disk = content(0, 2);
  write(join(root, "src/file_0.txt"), disk);
  await n.wait("return view.disk_conflict and not view.updating");
  await n.lua("vim.api.nvim_buf_set_lines(source,0,-1,false,...)", lines(disk));
  await n.request("nvim_command", "DiffreelRefresh");
  await n.wait("return view.ready and not view.updating");
  assert(
    !(await n.lua("return view.disk_conflict")),
    String("Matching draft retained a stale conflict"),
  );
  await n.request("nvim_command", "write!");
  await n.request("nvim_command", "DiffreelRefresh");
  await n.wait(
    "return view.ready and not view.updating and not vim.bo[source].modified",
  );
  assert(
    !(await n.lua(
      "return vim.wo[view.right_win].winbar:find('Unsaved',1,true)~=nil",
    )),
    String("Saved buffer retained its unsaved label"),
  );
}

export async function bdelete_explorer(n: Nvim, _root: string, _out: string) {
  await n.request("nvim_command", "bdelete");
  await n.wait("return not view.alive", 2);
  assert(equal(await n.lua("return vim.v.errmsg"), ""));
}

export async function replace_left(n: Nvim, root: string, _out: string) {
  await n.lua("vim.api.nvim_set_current_win(view.left_win)");
  await n.lua(
    "vim.api.nvim_cmd({cmd='edit',args={...}}, {})",
    String(join(root, "src/file_1.txt")),
  );
  await n.wait("return not view.alive", 2);
  assert(
    equal(
      await n.lua("return vim.api.nvim_buf_get_name(0)"),
      String(join(root, "src/file_1.txt")),
    ),
  );
  assert(equal(await n.lua("return vim.v.errmsg"), ""));
}

export async function move_right(n: Nvim, _root: string, _out: string) {
  await n.lua(
    "vim.api.nvim_set_current_win(view.right_win);_G.source=view.right_buf",
  );
  await n.request("nvim_input", "\u0017T");
  await n.wait("return not view.alive", 2);
  assert(
    await n.lua(
      "return vim.api.nvim_get_current_buf()==source and not vim.wo.diff",
    ),
  );
}

export async function extra_split(n: Nvim, _root: string, _out: string) {
  await n.lua("vim.api.nvim_set_current_win(view.right_win)");
  await n.request("nvim_input", "\u0017v");
  await n.request("nvim_input", "\u0017c");
  await steady(n);
  assert(await n.lua("return view.alive and vim.wo[view.right_win].diff"));
  await n.request("nvim_command", "DiffreelClose");
  assert(!(await n.lua("return view.alive")));
}

export async function invalid_revision(n: Nvim, _root: string, _out: string) {
  await n.request("nvim_command", "DiffreelClose");
  await n.request("nvim_command", "Diffreel revision-that-does-not-exist");
  await n.wait(
    "_G.view=require('diffreel').get_current();return view and view.error and not view.updating",
  );
  assert(!includes(n.text(), "No changes"));
  await n.request("nvim_input", "R");
  await n.wait("return view.error and not view.updating");
  await n.request("nvim_input", "q");
  await n.wait("return not view.alive");
  await n.request("nvim_command", "Diffreel");
  await n.wait(
    "_G.view=require('diffreel').get_current();return view and view.ready and not view.error",
  );
}

export async function invalid_arguments(n: Nvim, _root: string, _out: string) {
  const count = await n.lua("return #vim.api.nvim_list_tabpages()");
  const result = await n.lua(
    "local ok,err=pcall(vim.cmd,'Diffreel HEAD HEAD ignored');return {ok=ok,error=tostring(err)}",
  );
  assert(
    !(result["ok"]),
    String("An extra comparison argument was silently ignored"),
  );
  assert(equal(await n.lua("return #vim.api.nvim_list_tabpages()"), count));
}

export async function rapid_open_close(n: Nvim, _root: string, _out: string) {
  await n.request("nvim_command", "DiffreelClose");
  for (const _ of range(20)) {
    await n.request("nvim_command", "Diffreel");
    await n.request("nvim_input", "q");
    await n.wait("return vim.tbl_count(require('diffreel').views)==0");
  }
  assert(
    equal(
      await n.lua(
        "local count=0;for _,b in ipairs(vim.api.nvim_list_bufs())do if vim.api.nvim_buf_get_name(b):match('^diffreel:')then count=count+1 end end;return count",
      ),
      0,
    ),
  );
  await n.request("nvim_command", "Diffreel");
  await n.wait(
    "_G.view=require('diffreel').get_current();return view and view.ready",
  );
  assert(equal(await n.lua("return vim.v.errmsg"), ""));
}

export async function mixed_updates(n: Nvim, root: string, out: string) {
  let hashes, path, versions;
  for (const i of range(3, 40)) {
    write(join(root, "src/file_" + String(i) + ".txt"), content(i, 0));
  }
  await git(root, "add", ".");
  await git(root, "commit", "-qm", "agent checkpoint");
  const head = await git(root, "rev-parse", "HEAD");
  const baseline = Object.fromEntries(
    (range(40)).map((
      i,
    ) => [
      "src/file_" + String(i) + ".txt",
      read(join(root, "src/file_" + String(i) + ".txt")),
    ]),
  );
  await n.wait(
    ("return view.comparison.left==" + JSON.stringify(head)) +
      " and #view.entries==0 and view.ready",
  );
  const rng = new Random(71);
  for (const epoch of range(8)) {
    versions = Object.fromEntries(
      (range(40)).map((
        i,
      ) => ["src/file_" + String(i) + ".txt", content(i, 100 + epoch)]),
    );
    for (
      const path of rng.sample(
        Object.keys(versions),
        Object.keys(versions).length,
      )
    ) {
      write(join(root, path), versions[path]);
    }
    hashes = Object.fromEntries(
      await Promise.all(
        (Object.entries(versions)).map(async (
          [path, data],
        ) => [path, await sha256(encoder.encode(data))]),
      ),
    );
    await n.lua("_G.expected=...", hashes);
    await n.wait(
      "if not view.ready or view.updating or #view.entries~=40 then return false end;for p,h in pairs(_G.expected)do if not view.by_path[p]or view.by_path[p].right.content_id~=h then return false end end;return true",
    );
    path = "src/file_" + String(rng.randrange(40)) + ".txt";
    await select(n, path);
    assert(
      equal(
        (await n.lua(
          "return vim.api.nvim_buf_get_lines(view.left_buf,0,-1,false)",
        )).join("\n") + "\n",
        baseline[path],
      ),
    );
    assert(
      equal(
        (await n.lua(
          "return vim.api.nvim_buf_get_lines(view.right_buf,0,-1,false)",
        )).join("\n") + "\n",
        versions[path],
      ),
    );
    assert(
      equal(
        await n.lua(
          "return vim.api.nvim_win_call(view.right_win,function()return vim.fn.diff_hlID(1,1)end)",
        ),
        0,
      ),
    );
    await n.request(
      "nvim_ui_try_resize",
      100 + (20 * (epoch % 3)),
      30 + ((epoch % 3) * 4),
    );
    if ((epoch % 2)) {
      await n.request("nvim_command", "DiffreelClose");
      await n.request("nvim_command", "Diffreel");
      await n.wait(
        "_G.view=require('diffreel').get_current();return view and view.ready and not view.updating",
      );
    }
  }
  n.capture(join(out, "screenshots"), "mixed-forty-files");
  for (const [path, data] of Object.entries(baseline)) {
    write(join(root, path), data);
  }
  await n.wait("return view.ready and not view.updating and #view.entries==0");
  await n.request("nvim_command", "DiffreelClose");
  assert(equal(await n.lua("return vim.v.errmsg"), ""));
  assert(equal(await git(root, "status", "--porcelain"), ""));
}

export async function syntax_switch(n: Nvim, root: string, _out: string) {
  write(join(root, "code.lua"), "local value = 1\nreturn value\n");
  write(join(root, "plain.txt"), "local plain text\n");
  await git(root, "add", ".");
  await git(root, "commit", "-qm", "language fixtures");
  write(join(root, "code.lua"), "local value = 2\nreturn value\n");
  write(join(root, "plain.txt"), "local changed plain text\n");
  await n.wait(
    "return view.ready and not view.updating and view.by_path['code.lua'] and view.by_path['plain.txt']",
  );
  await select(n, "code.lua");
  assert(
    await n.lua("return vim.treesitter.highlighter.active[view.left_buf]~=nil"),
    String("Lua parser not active in fixture"),
  );
  await select(n, "plain.txt");
  assert(
    await n.lua("return vim.treesitter.highlighter.active[view.left_buf]==nil"),
    String("Plain text retained the previous Lua highlighter"),
  );
}

export async function git_failure(n: Nvim, root: string, _out: string) {
  const index = join(root, ".git/index");
  const saved = bytes(index);
  write(
    index,
    new Uint8Array([
      105,
      110,
      118,
      97,
      108,
      105,
      100,
      32,
      105,
      110,
      100,
      101,
      120,
    ]),
  );
  await n.request("nvim_input", "R");
  await n.wait("return view.error and not view.updating");
  assert(
    equal(
      await n.lua(
        "return vim.api.nvim_buf_get_lines(view.right_buf,0,1,false)[1]",
      ),
      "header 0",
    ),
  );
  write(index, saved);
  await n.request("nvim_input", "R");
  await n.wait("return view.ready and not view.error and not view.updating");
}

export async function repeated_watcher_error(
  n: Nvim,
  root: string,
  _out: string,
) {
  const config = join(root, ".git/config");
  const saved = bytes(config);
  await n.lua(
    `
      _G.failed_updates=0
      local backend=view.manager.backend
      local notify=backend.notify
      backend.notify=function(method,params)
        notify(method,params)
        if method=='comparison/updated' and params.error then failed_updates=failed_updates+1 end
      end
    `,
  );
  try {
    write(config, "invalid config\n");
    await n.wait("return failed_updates>=1", RECONCILE_TIMEOUT);
    assert(
      await n.lua("return view.error and not view.updating"),
      String("Completed watcher failure remained updating"),
    );
    write(join(root, "src/file_0.txt"), content(0, 2));
    await n.wait("return failed_updates>=2", RECONCILE_TIMEOUT);
    assert(
      await n.lua("return view.error and not view.updating"),
      String("Repeated watcher failure remained updating"),
    );
    assert(
      equal(
        await n.lua(
          "return vim.api.nvim_buf_get_lines(view.right_buf,1,2,false)[1]",
        ),
        "value 1",
      ),
    );
  } finally {
    write(config, saved);
  }
  await n.request("nvim_command", "DiffreelRefresh");
  await n.wait("return view.ready and not view.updating and not view.error");
  assert(
    equal(
      await n.lua(
        "return vim.api.nvim_buf_get_lines(view.right_buf,1,2,false)[1]",
      ),
      "value 2",
    ),
  );
}

export async function rename_reappear(n: Nvim, root: string, _out: string) {
  const replacement = "src/名前 [copy]%0.txt";
  await n.lua("_G.renamed_path=...", replacement);
  Deno.renameSync(join(root, "src/file_0.txt"), join(root, replacement));
  await git(root, "add", "-A");
  await n.wait(
    "return view.ready and not view.updating and view.by_path[_G.renamed_path]",
    RECONCILE_TIMEOUT,
  );
  await select(n, replacement);
  assert(
    equal(
      await n.lua(
        "return vim.api.nvim_buf_get_lines(view.left_buf,0,1,false)[1]",
      ),
      "header 0",
    ),
  );
  assert(
    equal(
      await n.lua("return vim.api.nvim_buf_get_name(view.right_buf)"),
      String(join(root, replacement)),
    ),
  );
  assert(
    equal(
      await n.lua("return vim.b[view.left_buf].diffreel_path"),
      replacement,
    ),
  );
  write(join(root, "src/file_0.txt"), content(0, 0));
  await git(root, "add", "-A");
  await n.wait(
    'return view.ready and not view.updating and not view.by_path["src/file_0.txt"] and view.by_path[_G.renamed_path].left.exists==false',
    RECONCILE_TIMEOUT,
  );
  assert(
    equal(
      await n.lua(
        "return vim.api.nvim_buf_get_lines(view.right_buf,0,1,false)[1]",
      ),
      "header 0",
    ),
  );
}

export async function ignore_change(n: Nvim, root: string, _out: string) {
  write(join(root, "scratch.tmp"), "untracked\n");
  await n.wait(
    "return view.ready and not view.updating and view.by_path['scratch.tmp']",
    RECONCILE_TIMEOUT,
  );
  write(join(root, ".gitignore"), "scratch.tmp\nsrc/file_1.txt\n");
  await n.wait(
    "return view.ready and not view.updating and not view.by_path['scratch.tmp'] and view.by_path['src/file_1.txt']",
    RECONCILE_TIMEOUT,
  );
  await select(n, "src/file_1.txt");
  assert(
    equal(
      await n.lua(
        "return vim.api.nvim_buf_get_lines(view.right_buf,0,1,false)[1]",
      ),
      "header 1",
    ),
  );
}

export async function toggle_review(n: Nvim, root: string, out: string) {
  async function toggle() {
    if (n.normal) {
      await n.request("nvim_input", ",gD");
    } else {
      await n.request("nvim_command", "Diffreel");
    }
  }
  async function opened() {
    await n.wait(
      "_G.view=require('diffreel').get_current();return view and view.ready and not view.updating",
    );
  }
  await n.lua("_G.original_tab=view.return_tab;_G.source=view.right_buf");
  for (const pane of ["explorer_win", "left_win", "right_win"]) {
    await n.lua("vim.api.nvim_set_current_win(view[...])", pane);
    if ((equal(pane, "right_win"))) {
      await n.request("nvim_input", "gg0Cdraft survives toggle\u001b");
      await n.wait("return vim.bo[source].modified");
    }
    await toggle();
    await n.wait("return not view.alive", 2);
    assert(
      await n.lua("return vim.api.nvim_get_current_tabpage()==original_tab"),
    );
    assert(
      equal(await n.lua('return vim.tbl_count(require("diffreel").views)'), 0),
    );
    await toggle();
    await opened();
  }
  assert(
    await n.lua("return view.right_buf==source and vim.bo[source].modified"),
  );
  assert(
    equal(
      await n.lua("return vim.api.nvim_buf_get_lines(source,0,1,false)[1]"),
      "draft survives toggle",
    ),
  );
  assert(equal(read(join(root, "src/file_0.txt")), content(0, 1)));
  await n.lua("vim.api.nvim_set_current_win(view.right_win)");
  await n.request("nvim_command", "vsplit");
  await toggle();
  await n.wait("return not view.alive", 2);
  await toggle();
  await opened();
  await n.lua("_G.parent_view=view");
  await n.request("nvim_command", "Diffreel HEAD");
  await opened();
  assert(await n.lua("return parent_view.alive and view~=parent_view"));
  await toggle();
  await n.wait("return not view.alive", 2);
  assert(
    await n.lua(
      "return parent_view.alive and vim.api.nvim_get_current_tabpage()==parent_view.tab",
    ),
  );
  await n.lua("_G.view=parent_view");
  await toggle();
  await n.wait("return not view.alive", 2);
  await n.lua('_G.previous_sequence=require("diffreel").sequence');
  if (n.normal) {
    await n.request("nvim_input", ",gD,gD");
  } else {
    await n.lua('vim.cmd("Diffreel");vim.cmd("Diffreel")');
  }
  await n.wait(
    'local k=require("diffreel");return k.sequence==previous_sequence+1 and next(k.views)==nil',
  );
  assert(
    await n.lua(
      "return vim.api.nvim_get_current_tabpage()==original_tab and vim.bo[source].modified",
    ),
  );
  assert(
    equal(
      await n.lua("return vim.api.nvim_buf_get_lines(source,0,1,false)[1]"),
      "draft survives toggle",
    ),
  );
  n.capture(join(out, "screenshots"), "toggle-closed");
}

export const CASES = {
  ["dirty-delete"]: dirty_delete,
  ["close-explorer"]: async (
    n: Nvim,
    r: string,
    o: string,
  ) => (await pane_close(n, r, o, "explorer_win")),
  ["close-left"]: async (
    n: Nvim,
    r: string,
    o: string,
  ) => (await pane_close(n, r, o, "left_win")),
  ["close-right"]: async (
    n: Nvim,
    r: string,
    o: string,
  ) => (await pane_close(n, r, o, "right_win")),
  ["only-right"]: only_window,
  ["rapid-selection"]: rapid_selection,
  ["tree-navigation"]: tree_navigation,
  ["dirty-binary"]: dirty_binary,
  ["dirty-delete-close"]: dirty_delete_close,
  ["dirty-matches-disk"]: dirty_matches_disk,
  ["dirty-head"]: dirty_head,
  ["dirty-baseline"]: dirty_baseline,
  ["dirty-ignored"]: dirty_ignored,
  ["navigation-head"]: async (
    n: Nvim,
    r: string,
    o: string,
  ) => (await dirty_head(n, r, o, true)),
  ["save-undo"]: save_undo,
  ["buffer-matches-disk"]: buffer_matches_disk,
  ["bdelete-explorer"]: bdelete_explorer,
  ["replace-left"]: replace_left,
  ["move-right-tab"]: move_right,
  ["extra-split"]: extra_split,
  ["move-clone-tab"]: move_clone,
  ["ordinary-edit-tab"]: edit_tab,
  ["multiple-comparisons"]: multiple_comparisons,
  ["invalid-revision"]: invalid_revision,
  ["invalid-arguments"]: invalid_arguments,
  ["rapid-open-close"]: rapid_open_close,
  ["mixed-updates"]: mixed_updates,
  ["syntax-switch"]: syntax_switch,
  ["quit-application"]: quit_application,
  ["worker-crash"]: worker_crash,
  ["git-failure"]: git_failure,
  ["repeated-watcher-error"]: repeated_watcher_error,
  ["rename-reappear"]: rename_reappear,
  ["ignore-change"]: ignore_change,
  ["toggle"]: toggle_review,
};

async function main() {
  const args = argumentsFor({
    output: "",
    daemon: "",
    backend: ["rust"],
    cases: Object.keys(CASES),
    normal: false,
  }, ["output", "daemon"]);
  const output = resolve(String(args.output));
  mkdir(join(output, "artifacts"));
  const results: Record<string, unknown>[] = [], runId = String(Date.now());
  for (const backend of args.backend as string[]) {
    for (const name of args.cases as string[]) {
      assert(backend === "rust", "Unknown backend");
      assert(name in CASES, "Unknown case: " + name);
      using temp = temporary("diffreel-stability-");
      const root = temp.path;
      await fixture(root);
      const n = await Nvim.create(root, { normal: Boolean(args.normal) });
      n.requestTimeout = 5;
      n.caseLabel = `${args.normal ? "normal" : "minimal"}-${backend}-${name}`;
      const result: Record<string, unknown> = {
        case: name,
        backend,
        normal: args.normal,
      };
      try {
        await start(n, backend, resolve(String(args.daemon)));
        await CASES[name as keyof typeof CASES](n, root, output);
        result.passed = true;
      } catch (error) {
        Object.assign(result, { passed: false, error: failure(error) });
        n.capture(join(output, "screenshots"), "failure");
      } finally {
        try {
          await n.requestWithTimeout("nvim_input", ["\r"], 1);
        } catch {
          /* A quit scenario has already closed the channel. */
        }
        await n.close();
      }
      results.push(result);
      console.log(JSON.stringify(result));
      json(
        join(
          output,
          "artifacts",
          args.normal ? "stability-normal.json" : "stability.json",
        ),
        results,
      );
      json(join(output, "artifacts", `stability-${runId}.json`), results);
    }
  }
  Deno.exitCode = results.every((result) => result.passed) ? 0 : 1;
}
if (import.meta.main) await main();
