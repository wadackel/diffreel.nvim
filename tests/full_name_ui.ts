import { assert, assertEquals } from "@std/assert";
import { git, Nvim } from "./support.ts";
import {
  argumentsFor,
  join,
  mkdir,
  resolve,
  temporary,
  write,
} from "../scripts/lib.ts";

async function main() {
  const args = argumentsFor({ output: ".wadackel/qa/full-name" });
  const out = resolve(String(args.output));
  mkdir(out);
  using fixture = temporary("full-name-", out);
  const root = fixture.path;
  const name = "a-long-file-name-with-a-distinctive-ending.test.txt";
  await git(root, "init", "-qb", "main");
  write(join(root, name), "before\nsame\n");
  write(join(root, "z.txt"), "before\n");
  await git(root, "add", ".");
  await git(root, "commit", "-qm", "base");
  write(join(root, name), "after\nsame\n");
  write(join(root, "z.txt"), "after\n");
  const nvim = await Nvim.create(root, { columns: 120, rows: 36 });
  const shown = () =>
    nvim.wait(
      "return v.full_name and v.full_name.win and vim.api.nvim_win_is_valid(v.full_name.win)",
    );
  const hidden = () =>
    nvim.wait("return not v.full_name or not v.full_name.win");
  const geometry = async () => {
    await shown();
    await nvim.wait(`
      if not v.full_name or not v.full_name.win then return false end
      local line = vim.api.nvim_win_get_cursor(v.explorer_win)[1]
      local origin = vim.fn.screenpos(v.explorer_win, line, 1)
      local popup = vim.fn.screenpos(v.full_name.win, 1, 1)
      return origin.row == popup.row and origin.col == popup.col
    `);
    return await nvim.lua<number[]>(`
      vim.cmd('redraw!')
      local line = vim.api.nvim_win_get_cursor(v.explorer_win)[1]
      local origin = vim.fn.screenpos(v.explorer_win, line, 1)
      local popup = vim.fn.screenpos(v.full_name.win, 1, 1)
      assert(origin.row == popup.row and origin.col == popup.col, vim.inspect({origin, popup}))
      assert(vim.api.nvim_win_get_width(v.full_name.win) <= vim.o.columns - origin.col + 1)
      assert(vim.api.nvim_get_current_win() == v.explorer_win)
      assert(not vim.wo[v.full_name.win].wrap and not vim.wo[v.full_name.win].diff)
      assert(not vim.api.nvim_win_get_config(v.full_name.win).focusable)
      return {origin.row, origin.col}
    `);
  };
  try {
    await nvim.lua(
      `
      plugin = require('diffreel')
      plugin.setup({watch=false, explorer={width=24}})
      v = plugin.open({root=...})
    `,
      root,
    );
    await nvim.wait("return v.ready or v.error");
    await nvim.lua(`
      assert(not v.error, v.error)
      draft = v.right_buf
      vim.api.nvim_buf_set_lines(draft, 0, 1, false, {'draft'})
      vim.api.nvim_set_current_win(v.explorer_win)
      vim.api.nvim_win_set_cursor(v.explorer_win, {4, 0})
      local request = v.manager.backend.request
      requests = 0
      v.manager.backend.request = function(self, method, params, done)
        if method ~= 'debug/metrics' and method ~= 'view/update' then requests = requests + 1 end
        return request(self, method, params, done)
      end
    `);
    const [row, col] = await geometry();
    assert(nvim.text().split("\n")[row - 1].includes(name));
    assertEquals(col, 1);
    nvim.capture(out, "expanded");
    const identity = await nvim.lua(
      "return {v.full_name.win, v.full_name.buf, #vim.api.nvim_list_wins(), #vim.api.nvim_list_bufs()}",
    );
    await nvim.lua("vim.cmd('redraw!')");
    await nvim.lua("vim.cmd('redraw!')");
    assertEquals(
      await nvim.lua(
        "return {v.full_name.win, v.full_name.buf, #vim.api.nvim_list_wins(), #vim.api.nvim_list_bufs()}",
      ),
      identity,
    );
    await nvim.lua(`
      local state = v.full_name
      local tick = vim.api.nvim_buf_get_changedtick(state.buf)
      for _ = 1, 20 do require('diffreel.full_name').update(v) end
      vim.schedule(function()
        settled = state.win == v.full_name.win and tick == vim.api.nvim_buf_get_changedtick(state.buf)
      end)
    `);
    await nvim.wait("return settled");
    await nvim.request("nvim_input", "j");
    await hidden();
    await nvim.request("nvim_input", "k");
    await shown();
    await nvim.lua("vim.api.nvim_set_current_win(v.right_win)");
    await hidden();
    await nvim.lua("vim.api.nvim_set_current_win(v.explorer_win)");
    await shown();
    await nvim.request("nvim_input", "K");
    await nvim.wait("return v.path_popup ~= nil");
    await hidden();
    await nvim.request("nvim_input", "q");
    await shown();
    await nvim.request("nvim_input", "g?");
    await nvim.wait("return v.help ~= nil");
    await hidden();
    await nvim.request("nvim_input", "q");
    await shown();
    await nvim.lua("plugin.set_explorer(v, {full_name=false})");
    await hidden();
    await nvim.lua("plugin.set_explorer(v, {full_name=true})");
    await shown();
    await nvim.lua("vim.api.nvim_set_current_tabpage(v.return_tab)");
    await hidden();
    await nvim.lua("vim.api.nvim_set_current_tabpage(v.tab)");
    await shown();
    await nvim.lua("plugin.toggle_explorer(v)");
    await hidden();
    await nvim.lua(
      "plugin.toggle_explorer(v); vim.api.nvim_set_current_win(v.explorer_win)",
    );
    await shown();
    for (const position of ["right", "bottom", "top", "left"]) {
      await nvim.lua(
        "plugin.set_explorer(v, {position=...}); vim.api.nvim_set_current_win(v.explorer_win)",
        position,
      );
      if (position === "bottom" || position === "top") {
        await nvim.request("nvim_ui_try_resize", 60, 36);
        await nvim.lua(
          "vim.wo[v.explorer_win].number=true; vim.wo[v.explorer_win].numberwidth=20",
        );
      }
      const [line, column] = await geometry();
      if (position === "right") {
        assert(column > 90);
        assert(!nvim.text().split("\n")[line - 1].includes(name));
        nvim.capture(out, "right-edge");
      } else if (position === "bottom" || position === "top") {
        assert(column >= 20);
        nvim.capture(out, position + "-gutter");
        await nvim.lua("vim.wo[v.explorer_win].number=false");
        await hidden();
        await nvim.request("nvim_ui_try_resize", 120, 36);
      }
    }
    await nvim.lua("vim.wo[v.explorer_win].wrap=true");
    await hidden();
    await nvim.lua("vim.wo[v.explorer_win].wrap=false");
    await shown();
    await nvim.lua(
      "vim.cmd('normal! 2zl'); assert(vim.fn.winsaveview().leftcol > 0)",
    );
    await hidden();
    await nvim.lua(
      "vim.api.nvim_win_call(v.explorer_win, function() vim.fn.winrestview({leftcol=0}) end)",
    );
    await shown();
    await nvim.request("nvim_ui_try_resize", 100, 30);
    await geometry();
    await nvim.lua("vim.api.nvim_win_set_width(v.explorer_win, 70)");
    await hidden();
    await nvim.lua("vim.api.nvim_win_set_width(v.explorer_win, 24)");
    await geometry();
    await nvim.lua(`
      assert(requests == 0, 'Name expansion requested repository data')
      assert(v.right_buf == draft and vim.bo[draft].modified)
      assert(vim.api.nvim_buf_get_lines(draft, 0, 1, false)[1] == 'draft')
      local win, buf = v.full_name.win, v.full_name.buf
      plugin.close(v)
      assert(not vim.api.nvim_win_is_valid(win) and not vim.api.nvim_buf_is_valid(buf))
      assert(vim.api.nvim_buf_is_valid(draft) and vim.bo[draft].modified)
    `);

    const deep = "long-directory/子ディレクトリ/nested/" + name;
    mkdir(join(root, "long-directory/子ディレクトリ/nested"));
    write(join(root, deep), "new file\n");
    await nvim.lua(
      "v = plugin.open({root=..., line_stats=true, selected_file=select(2, ...)})",
      root,
      deep,
    );
    await nvim.wait("return v.ready or v.error");
    await nvim.lua(
      "assert(not v.error, v.error); vim.api.nvim_set_current_win(v.explorer_win)",
    );
    await nvim.lua("plugin.refresh(v)");
    await nvim.wait(
      "for _, row in ipairs(v.rows) do if row.path:find('long-directory/', 1, true) then return true end end",
    );
    await nvim.lua("plugin.select(v, ...)", deep);
    await nvim.wait(
      "return v.selected_path:find('long-directory/', 1, true) ~= nil",
    );
    for (const mode of ["tree", "compact", "list"]) {
      await nvim.lua(
        `
        local mode, path = ...
        plugin.set_explorer(v, {mode=mode == 'list' and 'list' or 'tree', compact=mode == 'compact'})
        for i, row in ipairs(v.rows) do
          if row.path == path then vim.api.nvim_win_set_cursor(v.explorer_win, {i+3, 0}); break end
        end
      `,
        mode,
        deep,
      );
      await geometry();
      const text = await nvim.lua<string>(
        "return vim.api.nvim_buf_get_lines(v.full_name.buf, 0, 1, false)[1]",
      );
      assert(text.includes(mode === "list" ? deep : name));
      nvim.capture(out, mode);
      if (mode === "compact") {
        await nvim.request("nvim_input", "k");
        await geometry();
        assert(
          (await nvim.lua<string>(
            "return vim.api.nvim_buf_get_lines(v.full_name.buf, 0, 1, false)[1]",
          )).includes("long-directory/子ディレクトリ/nested"),
        );
      }
    }
    await nvim.lua("vim.cmd('normal! zt')");
    await geometry();
    await nvim.lua("vim.cmd('normal! 2\\25')");
    await geometry();
    await nvim.lua("vim.cmd('colorscheme default')");
    await geometry();
    await nvim.lua(`
      local marks = vim.api.nvim_buf_get_extmarks(v.full_name.buf, -1, 0, -1, {details=true})
      local selected = false
      for _, mark in ipairs(marks) do
        if mark[4].line_hl_group == 'DiffreelExplorerSelected' then selected = true end
      end
      assert(selected, 'The full row lost the selected-file highlight')
      closing_buf = v.full_name.buf
      require('diffreel.full_name').update(v)
      plugin.close(v)
    `);
    await nvim.lua(
      "assert(not v.alive and not v.full_name and not vim.api.nvim_buf_is_valid(closing_buf))",
    );
    write(join(out, "result.json"), JSON.stringify({ passed: true }) + "\n");
  } finally {
    nvim.capture(out, "final");
    await nvim.close();
  }
}

if (import.meta.main) await main();
