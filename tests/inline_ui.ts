import { git, Nvim } from "./support.ts";
import {
  argumentsFor,
  assert,
  equal,
  first,
  includes,
  join,
  lines as splitLines,
  mkdir,
  range,
  resolve,
  temporary as makeTemp,
  write,
} from "../scripts/lib.ts";

export async function presentation_scenarios(out: string) {
  let lines, replacement, nvim, offset, old, prefix, root;
  {
    using temp_temporary = makeTemp("diffreel-", out);
    const temporary = temp_temporary.path;
    root = resolve(temporary);
    await git(root, "init", "-qb", "main");
    write(join(root, "file.txt"), "\told value\n");
    await git(root, "add", ".");
    await git(root, "commit", "-qm", "base");
    write(join(root, "file.txt"), "\tnew value\n");
    nvim = await Nvim.create(root);
    try {
      await nvim.lua(
        "require('diffreel').setup({watch=false}); _G.v=require('diffreel').open({layout='inline',file='file.txt'})",
      );
      await nvim.wait(
        "return v.ready and require('diffreel.inline').current(v)",
      );
      await nvim.request("nvim_command", "redraw!");
      lines = splitLines(nvim.text());
      old = first(
        (lines.filter((line) => (includes(line, "old value")))).map((line) =>
          line.indexOf("old value")
        ),
      );
      replacement = first(
        (lines.filter((line) => (includes(line, "new value")))).map((line) =>
          line.indexOf("new value")
        ),
      );
      assert(
        equal(old, replacement),
        String({ ["old_column"]: old, ["new_column"]: replacement }),
      );
      await nvim.request(
        "nvim_command",
        "setlocal nonumber foldcolumn=0 signcolumn=yes:2",
      );
      await nvim.request("nvim_command", "redraw!");
      await nvim.wait("return require('diffreel.inline').current(v)");
      offset = await nvim.lua(
        "return vim.fn.getwininfo(v.right_win)[1].textoff",
      );
      prefix = await nvim.lua(
        "local marks=vim.api.nvim_buf_get_extmarks(v.right_buf,v.inline_namespace,0,-1,{details=true});for _,m in ipairs(marks) do if m[4].virt_lines then return m[4].virt_lines[1][1][1] end end",
      );
      assert(
        equal(prefix.length, offset),
        String({ ["prefix"]: prefix, ["offset"]: offset }),
      );
      await nvim.lua(
        "vim.bo[v.left_buf].vartabstop='4,8';vim.bo[v.right_buf].vartabstop='4,8'",
      );
      await nvim.request("nvim_command", "redraw!");
      await nvim.wait("return require('diffreel.inline').current(v)");
      await nvim.request("nvim_command", "setlocal signcolumn=no");
      await nvim.request("nvim_command", "redraw!");
      await nvim.wait("return require('diffreel.inline').current(v)");
      await nvim.request("nvim_command", "redraw!");
      lines = splitLines(nvim.text());
      old = first(
        (lines.filter((line) => (includes(line, "old value")))).map((line) =>
          line.indexOf("old value")
        ),
      );
      replacement = first(
        (lines.filter((line) => (includes(line, "new value")))).map((line) =>
          line.indexOf("new value")
        ),
      );
      assert(
        equal(old, replacement) && equal(replacement, 4),
        String({ ["old_column"]: old, ["new_column"]: replacement }),
      );
      nvim.capture(out, "inline-tabs-gutter");
    } finally {
      await nvim.close();
    }
  }
}

export async function inlineScenario(out: string) {
  let before, frame, middle, nvim, root;
  {
    using temp_temporary = makeTemp("diffreel-", out);
    const temporary = temp_temporary.path;
    root = resolve(temporary);
    await git(root, "init", "-qb", "main");
    middle = (range(1, 31)).map((i) => ("same " + String(i)));
    before = ["removed at beginning", ...middle, "removed at end"];
    write(join(root, "file.txt"), before.join("\n") + "\n");
    await git(root, "add", ".");
    await git(root, "commit", "-qm", "base");
    middle[14] = "changed middle";
    write(join(root, "file.txt"), middle.join("\n") + "\n");
    nvim = await Nvim.create(root, { columns: 130, rows: 35 });
    try {
      await nvim.lua(
        "vim.opt.diffopt:append('context:2'); vim.cmd.edit(...); _G.source=vim.api.nvim_get_current_buf(); _G.ordinary=vim.api.nvim_get_current_win(); _G.original_fold=vim.wo.foldexpr; require('diffreel').setup({watch=false}); _G.v=require('diffreel').open({layout='inline',explorer={visible=false}})",
        String(join(root, "file.txt")),
      );
      await nvim.wait("return v.ready and not v.inline_pending or v.error");
      assert(
        await nvim.lua(
          "return not v.error and v.layout=='inline' and v.right_buf==source",
        ),
        String(await nvim.lua("return v.error")),
      );
      assert(
        await nvim.lua(
          "return #vim.api.nvim__ns_get(v.inline_namespace).wins==1",
        ),
      );
      await nvim.request("nvim_command", "redraw!");
      assert(
        includes(nvim.text(), "removed at beginning"),
        String("Initial BOF deletions were hidden"),
      );
      nvim.capture(out, "inline-initial");
      await nvim.request("nvim_input", "[H");
      await nvim.wait("return vim.api.nvim_win_get_cursor(v.right_win)[1]==1");
      await nvim.request("nvim_command", "redraw!");
      assert(
        includes(nvim.text(), "removed at beginning"),
        String("Deleted BOF lines were hidden"),
      );
      await nvim.lua("vim.fn.setreg('a','keep')");
      await nvim.request("nvim_input", '"ayih');
      await nvim.wait("return vim.fn.mode()=='n'");
      assert(equal(await nvim.lua("return vim.fn.getreg('a')"), "keep"));
      await nvim.request("nvim_input", "]c");
      await nvim.wait("return vim.api.nvim_win_get_cursor(v.right_win)[1]==15");
      await nvim.request("nvim_input", '"ayih');
      await nvim.wait("return vim.fn.getreg('a')=='changed middle\\n'");
      assert(await nvim.lua("return vim.fn.getregtype('a')=='V'"));
      await nvim.lua(
        `
              for row,level in ipairs(v.inline_cache.folds) do if level>0 then _G.fold_row=row; break end end
              assert(fold_row,"Missing inline context folds")
              vim.cmd(fold_row..'foldopen')
              assert(vim.fn.foldclosed(fold_row)==-1)
            `,
      );
      await nvim.lua(
        "vim.api.nvim_buf_set_lines(source,14,15,false,{'draft middle'})",
      );
      await nvim.wait(
        "return not v.inline_pending and require('diffreel.inline').current(v)",
      );
      assert(await nvim.lua("return vim.bo[source].modified"));
      assert(
        await nvim.lua("return vim.fn.foldclosed(fold_row)==-1"),
        String("Inline refresh closed an opened fold"),
      );
      await nvim.request("nvim_input", "]H");
      await nvim.wait("return vim.api.nvim_win_get_cursor(v.right_win)[1]==30");
      await nvim.lua("vim.fn.setreg('a','keep')");
      await nvim.request("nvim_input", '"ayih');
      await nvim.wait("return vim.fn.mode()=='n'");
      assert(equal(await nvim.lua("return vim.fn.getreg('a')"), "keep"));
      frame = nvim.frames;
      await nvim.request("nvim_command", "redraw!");
      await nvim.waitFrame(frame);
      assert(
        includes(nvim.text(), "removed at end"),
        String("Deleted EOF lines were hidden"),
      );
      nvim.capture(out, "inline-draft");
      await nvim.request("nvim_input", "[H");
      await nvim.wait("return vim.api.nvim_win_get_cursor(v.right_win)[1]==1");
      await nvim.request("nvim_command", "redraw!");
      assert(
        includes(nvim.text(), "removed at beginning"),
        String("Hunk navigation hid BOF deletions"),
      );
      await nvim.lua("vim.api.nvim_set_current_tabpage(v.return_tab)");
      await nvim.request("nvim_command", "redraw!");
      assert(
        !includes(nvim.text(), "removed at"),
        String("Inline deletions leaked into an ordinary window"),
      );
      assert(await nvim.lua("return vim.wo[ordinary].foldexpr==original_fold"));
      await nvim.lua(
        "vim.api.nvim_set_current_tabpage(v.tab); vim.api.nvim_win_close(v.right_win,true)",
      );
      await nvim.wait("return not v.alive");
      assert(
        await nvim.lua(
          "return vim.bo[source].modified and not require('diffreel.lease').buffers[source]",
        ),
      );
      assert(
        await nvim.lua("return #vim.api.nvim_list_wins() == 1"),
        String(await nvim.lua("return vim.api.nvim_list_wins()")),
      );
    } finally {
      await nvim.close();
    }
  }
  await presentation_scenarios(out);
  console.log(JSON.stringify({ ["passed"]: true }));
}
if (import.meta.main) {
  const args = argumentsFor({ output: ".wadackel/qa/inline-ui" });
  const out = resolve(String(args.output));
  mkdir(out);
  await inlineScenario(out);
}
