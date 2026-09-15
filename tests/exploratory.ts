import { git, Nvim } from "./support.ts";
import {
  argumentsFor,
  assert,
  equal,
  failure,
  includes,
  join,
  json,
  lines,
  mkdir,
  now,
  range,
  remove,
  resolve,
  temporary,
  write,
} from "../scripts/lib.ts";

import { content, fixture, steady } from "./stability.ts";
export async function spy_requests(n: Nvim) {
  await n.lua(
    `
      _G.requests = vim.empty_dict()
      local backend = view.manager.backend
      local request = backend.request
      backend.request = function(self, method, params, done)
        requests[method] = (requests[method] or 0) + 1
        return request(self, method, params, done)
      end
    `,
  );
}

export async function edit_source(n: Nvim) {
  await n.lua(
    "vim.api.nvim_set_current_win(view.right_win);_G.source=view.right_buf",
  );
  await n.request("nvim_input", "gg0Cdraft\u001b");
  await n.wait("return vim.bo[source].modified and view.disk_conflict");
}

export async function boundary_work(n: Nvim, _root: string) {
  await spy_requests(n);
  await n.lua("for i=1,50 do require('diffreel').next_file(view,-1)end");
  await steady(n);
  const counts = await n.lua("return requests");
  assert(equal(counts["blob/read"] ?? 0, 0), String(counts));
  assert(equal(counts["view/update"] ?? 0, 0), String(counts));
  assert(await n.lua("return view.selected_path=='src/file_0.txt'"));
  return counts;
}

export async function duplicate_inspection(n: Nvim, root: string) {
  await edit_source(n);
  write(join(root, "src/file_0.txt"), content(0, 0));
  await spy_requests(n);
  await n.lua("require('diffreel').refresh(view)");
  await steady(n);
  const counts = await n.lua("return requests");
  assert(equal(counts["comparison/file"], 1), String(counts));
  assert(
    await n.lua("return view.right_buf==source and vim.bo[source].modified"),
  );
  assert(
    equal(
      await n.lua(
        "return vim.api.nvim_buf_get_lines(view.left_buf,0,-1,false)",
      ),
      lines(content(0, 0)),
    ),
  );
  return counts;
}

export async function nested_root(n: Nvim, root: string) {
  await n.lua(
    "_G.other=require('diffreel').open({root=...})",
    String(join(root, "src")),
  );
  await n.wait("return other.ready");
  const state = await n.lua(
    'return {shared=view.manager==other.manager,count=vim.tbl_count(require("diffreel").managers),root=other.root}',
  );
  assert(
    state["shared"] && (equal(state["count"], 1)) &&
      (equal(state["root"], String(root))),
    String(state),
  );
  return state;
}

export async function extra_window_commands(n: Nvim, root: string) {
  await edit_source(n);
  await n.request("nvim_command", "vsplit");
  await n.lua("_G.extra=vim.api.nvim_get_current_win()");
  assert(await n.lua("return require('diffreel').get_current()==nil"));
  write(join(root, "src/file_0.txt"), content(0, 2));
  await n.request("nvim_command", "DiffreelRefresh");
  const digest = await n.lua("return vim.fn.sha256(...)", content(0, 2));
  await n.wait(
    ("return view.by_path['src/file_0.txt'].right.content_id==" +
      JSON.stringify(digest)) + " and not view.updating",
    2,
  );
  assert(
    await n.lua(
      "return vim.api.nvim_get_current_win()==extra and vim.bo[source].modified",
    ),
  );
  await n.request("nvim_command", "DiffreelClose");
  await n.wait("return not view.alive", 2);
  assert(
    await n.lua(
      'return vim.bo[source].modified and vim.api.nvim_buf_get_lines(source,0,1,false)[1]=="draft"',
    ),
  );
}

export async function directory_replaced(n: Nvim, root: string) {
  remove(join(root, "src"));
  write(join(root, "src"), "replacement file\n");
  await n.lua("require('diffreel').refresh(view)");
  await n.wait("return not view.updating");
  const state = await n.lua("return {error=view.error,entries=#view.entries}");
  assert(!(state["error"]) && (equal(state["entries"], 4)), String(state));
  for (const i of range(3)) {
    assert(
      await n.lua(
        'local e=view.by_path[...];return e.status=="deleted" and not e.right.exists',
        "src/file_" + String(i) + ".txt",
      ),
    );
  }
  return state;
}

export async function tree_type_change(n: Nvim, root: string) {
  await git(root, "add", ".");
  await git(root, "commit", "-qm", "content update");
  remove(join(root, "src"));
  write(join(root, "src"), "replacement file\n");
  await git(root, "add", ".");
  await git(root, "commit", "-qm", "directory replacement");
  await n.lua(
    "_G.other=require('diffreel').open({left='HEAD~1',right='HEAD'})",
  );
  await n.wait("return other.ready and not other.updating");
  const paths = await n.lua(
    "local paths={};for _,row in ipairs(other.rows)do if not row.directory then paths[#paths+1]=row.path end end;return paths",
  );
  assert(
    equal(paths, [
      ...["src"],
      ...(range(3)).map((i) => ("src/file_" + String(i) + ".txt")),
    ]),
    String(paths),
  );
  return paths;
}

export async function read_error_path(n: Nvim, root: string) {
  let path, state;
  for (const name of ["ENOENT.txt", "ENOTDIR.txt"]) {
    path = join(root, name);
    write(path, "unreadable\n");
    Deno.chmodSync(path, 0);
    try {
      await n.lua(
        "_G.inspected=nil;view.manager.backend:request('comparison/file',{comparison_id=view.comparison.comparison_id,path=...},function(err,value)inspected={error=err,value=value}end)",
        name,
      );
      state = await n.wait("return inspected");
      assert(state["error"], String(state));
    } finally {
      Deno.chmodSync(path, 384);
    }
  }
}

export async function empty_conflict(n: Nvim, root: string) {
  await edit_source(n);
  await n.lua(
    "vim.api.nvim_set_current_win(view.explorer_win);vim.bo[source].modified=false",
  );
  for (const i of range(3)) {
    write(join(root, "src/file_" + String(i) + ".txt"), content(i, 0));
  }
  await n.lua("require('diffreel').refresh(view)");
  await n.wait("return view.ready and not view.updating and #view.entries==0");
  const state = await n.lua(
    "return {conflict=view.disk_conflict,lines=vim.api.nvim_buf_get_lines(view.explorer_buf,0,-1,false)}",
  );
  assert(
    !(state["conflict"]) &&
      (!includes(state["lines"], "Unsaved buffer differs from disk")),
    String(state),
  );
  return state;
}

export async function format_state(n: Nvim, root: string) {
  await edit_source(n);
  const disk =
    (await n.lua("return vim.api.nvim_buf_get_lines(source,0,-1,false)")).join(
      "\n",
    ) + "\n";
  write(join(root, "src/file_0.txt"), disk);
  await n.lua("require('diffreel').refresh(view)");
  await steady(n);
  assert(!(await n.lua("return view.disk_conflict")));
  await n.request("nvim_command", "setlocal fileformat=dos");
  await n.wait("return view.disk_conflict", 2);
  await n.request("nvim_command", "setlocal fileformat=unix");
  await n.wait("return not view.disk_conflict", 2);
  await n.request("nvim_command", "setlocal noendofline");
  await n.wait("return view.disk_conflict", 2);
  await n.request("nvim_command", "setlocal endofline bomb");
  await n.wait(
    'return view.disk_conflict and vim.wo[view.right_win].winbar:find("BOM",1,true)~=nil',
    2,
  );
  await n.request("nvim_command", "setlocal nobomb");
  await n.wait("return not view.disk_conflict", 2);
}

export async function invalid_setup(n: Nvim, _root: string) {
  const state = await n.lua(
    "local k=require('diffreel');local old=k.config;local ok=pcall(k.setup,{backend='invalid'});return {ok=ok,preserved=k.config==old}",
  );
  assert(!(state["ok"]) && state["preserved"], String(state));
  await n.lua("_G.other=require('diffreel').open()");
  await n.wait("return other.ready");
  assert(await n.lua("return other.manager==view.manager"));
}

export async function shared_hash(n: Nvim, _root: string) {
  for (const _ of range(2)) {
    await n.lua("_G.other=require('diffreel').open()");
    await n.wait("return other.ready and not other.selection_pending");
  }
  await n.lua(
    "_G.hashes=0;local hash=vim.fn.sha256;vim.fn.sha256=function(text)hashes=hashes+1;return hash(text)end;vim.api.nvim_set_current_win(other.right_win)",
  );
  await n.request("nvim_input", "gg0Cdraft across views\u001b");
  await n.wait("return view.disk_conflict and other.disk_conflict");
  const state = await n.lua(
    'return {hashes=hashes,views=vim.tbl_count(require("diffreel").views)}',
  );
  assert(equal(state["hashes"], 1), String(state));
  return state;
}

export async function api_edit(n: Nvim, _root: string) {
  await n.lua(
    "_G.source=view.right_buf;vim.api.nvim_buf_set_lines(source,0,1,false,{'edit while tree focused'})",
  );
  await n.wait("return view.disk_conflict", 2);
  assert(
    await n.lua("return vim.api.nvim_get_current_win()==view.explorer_win"),
  );
  assert(
    await n.lua(
      'return vim.wo[view.right_win].winbar:find("Unsaved buffer",1,true)~=nil',
    ),
  );
}

export async function lease_expr(n: Nvim, _root: string) {
  const state = await n.lua(
    `
      local lease = require('diffreel.lease')
      local values = {}
      vim.api.nvim_set_current_tabpage(view.return_tab)
      for _, borrowed in ipairs({false, true}) do
        local buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_set_current_buf(buf)
        vim.keymap.set('n', 'q', function() return 'i<Left>' end, {buffer=buf,expr=true,replace_keycodes=false})
        if borrowed then lease.acquire(buf, 'probe', function() return nil end, {q=function()end}) end
        vim.api.nvim_feedkeys('q', 'xt', false)
        values[#values+1] = vim.api.nvim_buf_get_lines(buf,0,-1,false)
        if borrowed then lease.release(buf, 'probe') end
      end
      return values
    `,
  );
  assert(
    (equal(state[0], ["<Left>"])) && (equal(state[1], state[0])),
    String(state),
  );
  return state;
}

export async function lease_cleanup(n: Nvim, _root: string) {
  const state = await n.lua(
    `
      local lease = require('diffreel.lease')
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_set_current_tabpage(view.return_tab)
      vim.api.nvim_set_current_buf(buf)
      vim.bo[buf].bufhidden, vim.bo[buf].autoread = '', false
      vim.keymap.set('n','q','gg',{buffer=buf})
      vim.keymap.set('n',']f','$',{buffer=buf})
      lease.acquire(buf,'probe',function()return nil end,{q=function()end,[']f']=function()end})
      local mapset = vim.fn.mapset
      vim.fn.mapset = function(mode,abbr,mapping)
        if mapping.lhs=='q' then error('Injected map restoration failure') end
        return mapset(mode,abbr,mapping)
      end
      local ok = pcall(lease.release,buf,'probe')
      vim.fn.mapset = mapset
      return {ok=ok,hidden=vim.bo[buf].bufhidden,autoread=vim.bo[buf].autoread,
        other=vim.fn.maparg(']f','n',false,true).rhs,released=lease.buffers[buf]==nil}
    `,
  );
  assert(
    !(state["ok"]) && state["released"] && (equal(state["hidden"], "")) &&
      !(state["autoread"]) && (equal(state["other"], "$")),
    String(state),
  );
  return state;
}

export const CASES = {
  ["boundary-work"]: boundary_work,
  ["duplicate-inspection"]: duplicate_inspection,
  ["nested-root"]: nested_root,
  ["extra-window-commands"]: extra_window_commands,
  ["directory-replaced"]: directory_replaced,
  ["tree-type-change"]: tree_type_change,
  ["read-error-path"]: read_error_path,
  ["empty-conflict"]: empty_conflict,
  ["format-state"]: format_state,
  ["invalid-setup"]: invalid_setup,
  ["shared-hash"]: shared_hash,
  ["api-edit"]: api_edit,
  ["lease-expr"]: lease_expr,
  ["lease-cleanup"]: lease_cleanup,
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
  mkdir(output);
  const results: Record<string, unknown>[] = [];
  for (const backend of args.backend as string[]) {
    for (const name of args.cases as string[]) {
      assert(backend === "rust", "Unknown backend");
      assert(name in CASES, "Unknown case: " + name);
      using temp = temporary("diffreel-exploratory-");
      const root = temp.path;
      await fixture(root);
      const n = await Nvim.create(root, { normal: Boolean(args.normal) });
      const result: Record<string, unknown> = {
          case: name,
          backend,
          normal: args.normal,
          watch: false,
        },
        started = now();
      try {
        await n.lua(
          "require('diffreel').setup({backend=select(1,...),daemon=select(2,...),watch=false});_G.view=require('diffreel').open()",
          backend,
          resolve(String(args.daemon)),
        );
        await steady(n);
        result.observed = await CASES[name as keyof typeof CASES](n, root);
        result.passed = true;
      } catch (error) {
        Object.assign(result, { passed: false, error: failure(error) });
        n.capture(join(output, "screenshots"), `${backend}-${name}-failure`);
      } finally {
        await n.close();
      }
      result.seconds = Number((now() - started).toFixed(3));
      results.push(result);
      json(join(output, "results.json"), results);
      console.log(JSON.stringify(result));
    }
  }
  Deno.exitCode = results.every((result) => result.passed) ? 0 : 1;
}
if (import.meta.main) await main();
