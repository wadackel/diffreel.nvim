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
  const args = argumentsFor({ output: ".wadackel/qa/explorer-resize" });
  const out = resolve(String(args.output));
  mkdir(out);
  using fixture = temporary("explorer-resize-", out);
  const root = fixture.path;
  const path = "a-long-file-name-for-resize.txt";
  await git(root, "init", "-qb", "main");
  write(join(root, path), "before\nsame\n");
  await git(root, "add", ".");
  await git(root, "commit", "-qm", "base");
  write(join(root, path), "after\nsame\n");
  const nvim = await Nvim.create(root, { columns: 160, rows: 48 });
  const resize = async (columns: number, rows: number) => {
    const serial = await nvim.lua<number>("return resize_events");
    await nvim.request("nvim_ui_try_resize", columns, rows);
    await nvim.wait(`return resize_events > ${serial}`);
    await nvim.lua("vim.cmd('redraw!')");
  };
  const width = () =>
    nvim.lua<number>("return vim.api.nvim_win_get_width(v.explorer_win)");
  try {
    await nvim.lua(
      `
      plugin = require('diffreel')
      resize_events, layout_events, width_calls, height_calls = 0, 0, 0, 0
      notices = {}
      vim.notify = function(message) notices[#notices + 1] = message end
      vim.api.nvim_create_autocmd('VimResized', { callback = function() resize_events = resize_events + 1 end })
      vim.api.nvim_create_autocmd('User', { pattern = 'DiffreelLayoutChanged', callback = function() layout_events = layout_events + 1 end })
      dynamic_width = function(ctx)
        assert(ctx.columns == vim.o.columns and ctx.lines == vim.o.lines)
        width_calls = width_calls + 1
        return math.floor(ctx.columns / 4)
      end
      dynamic_height = function(ctx)
        height_calls = height_calls + 1
        return math.floor(ctx.lines / 4)
      end
      function pane_ratio(view)
        local get = view.layout == 'stacked' and vim.api.nvim_win_get_height or vim.api.nvim_win_get_width
        local left, right = get(view.left_win), get(view.right_win)
        return left / (left + right)
      end
      function expect_ratio(view, expected)
        local get = view.layout == 'stacked' and vim.api.nvim_win_get_height or vim.api.nvim_win_get_width
        local left, right = get(view.left_win), get(view.right_win)
        assert(math.abs(left - (left + right) * expected) <= 1, vim.inspect({layout=view.layout,left=left,right=right,expected=expected}))
      end
      plugin.setup({watch=false, explorer={width=dynamic_width,height=dynamic_height}})
      assert(width_calls == 0 and height_calls == 0)
      v = plugin.open({root=...})
    `,
      root,
    );
    await nvim.wait("return v.ready or v.error");
    await nvim.lua(`
      assert(not v.error, v.error)
      assert(height_calls == 0)
      draft = v.right_buf
      vim.api.nvim_buf_set_lines(draft, 0, 1, false, {'draft'})
      local request = v.manager.backend.request
      sizing_requests = 0
      v.manager.backend.request = function(self, method, params, done)
        if method ~= 'debug/metrics' then sizing_requests = sizing_requests + 1 end
        return request(self, method, params, done)
      end
    `);
    assertEquals(await width(), 40);
    const full = await nvim.lua<string>("return v.rows[1].text");
    assert(full.includes(path));
    await resize(100, 32);
    await nvim.wait("return vim.api.nvim_win_get_width(v.explorer_win) == 25");
    await nvim.lua(
      "assert(math.abs(vim.api.nvim_win_get_width(v.left_win) - vim.api.nvim_win_get_width(v.right_win)) <= 1, 'Editor resize unbalanced the diff panes')",
    );
    assert(!(await nvim.lua<string>("return v.rows[1].text")).includes(path));
    assert((await nvim.lua<string>("return v.rows[1].text")).includes("…"));
    await nvim.wait("return v.full_name and v.full_name.win ~= nil");
    assert(nvim.text().includes(path));
    assert(nvim.text().includes("before") && nvim.text().includes("draft"));
    nvim.capture(out, "narrow");
    await resize(160, 48);
    await nvim.wait("return vim.api.nvim_win_get_width(v.explorer_win) == 40");
    assert(nvim.text().includes(path));
    await nvim.lua(`
      assert(layout_events == 0)
      local calls = width_calls
      plugin.set_explorer(v, {mode='list', compact=true})
      plugin.set_explorer(v, {position='left', height=dynamic_height})
      assert(width_calls == calls and height_calls == 0)
      assert(vim.api.nvim_win_get_width(v.explorer_win) == 40, 'An inactive-axis update resized the explorer')
      local events = layout_events
      plugin.set_explorer(v, {width=dynamic_width})
      assert(width_calls == calls + 1 and layout_events == events, vim.inspect({calls=calls,actual_calls=width_calls,events=events,actual_events=layout_events,width=vim.api.nvim_win_get_width(v.explorer_win)}))
      vim.api.nvim_win_set_width(v.explorer_win, 31)
      plugin.toggle_explorer(v)
      plugin.toggle_explorer(v)
      assert(vim.api.nvim_win_get_width(v.explorer_win) == 31)
    `);
    await resize(120, 40);
    await nvim.wait("return vim.api.nvim_win_get_width(v.explorer_win) == 30");
    await nvim.lua(
      "vim.api.nvim_win_set_width(v.explorer_win, 27); plugin.toggle_explorer(v); hidden_ratio = pane_ratio(v)",
    );
    const calls = await nvim.lua<number>("return width_calls");
    await resize(160, 48);
    await resize(120, 40);
    assertEquals(await nvim.lua("return width_calls"), calls);
    await nvim.lua(
      "assert(not v.explorer_win); expect_ratio(v, hidden_ratio); plugin.toggle_explorer(v); expect_ratio(v, hidden_ratio)",
    );
    assertEquals(await width(), 30);

    for (const layout of ["side_by_side", "stacked", "inline"]) {
      await nvim.lua("plugin.set_layout(v, ...)", layout);
      await nvim.wait(
        `return v.layout == '${layout}' and not v.inline_pending`,
      );
      for (const position of ["left", "right", "top", "bottom"]) {
        await nvim.lua("plugin.set_explorer(v, {position=...})", position);
        if (layout !== "inline") {
          await nvim.lua(`
            local get = v.layout == 'stacked' and vim.api.nvim_win_get_height or vim.api.nvim_win_get_width
            local set = v.layout == 'stacked' and vim.api.nvim_win_set_height or vim.api.nvim_win_set_width
            set(v.left_win, math.floor((get(v.left_win) + get(v.right_win)) * 0.3))
            expected_ratio = pane_ratio(v)
          `);
        }
        for (const [columns, rows] of [[160, 48], [100, 32], [120, 40]]) {
          await resize(columns, rows);
          const vertical = position === "left" || position === "right";
          await nvim.wait(
            `return vim.api.nvim_win_get_${
              vertical ? "width" : "height"
            }(v.explorer_win) == ${
              Math.floor((vertical ? columns : rows) / 4)
            }`,
          );
          await nvim.lua(`
            assert(v.alive and v.right_buf == draft and vim.bo[draft].modified)
            assert(vim.api.nvim_buf_get_lines(draft,0,1,false)[1] == 'draft')
            assert(not vim.wo[v.explorer_win].diff)
          `);
          if (layout === "inline") {
            await nvim.wait("return require('diffreel.inline').current(v)");
          } else {
            await nvim.lua("expect_ratio(v, expected_ratio)");
          }
        }
      }
    }
    await nvim.lua(`
      plugin.set_layout(v, 'side_by_side')
      plugin.set_explorer(v, {position='left'})
      assert(sizing_requests == 0, 'Sizing requested repository data')
      home = v.return_tab
      vim.api.nvim_win_set_width(v.explorer_win, 27)
      inactive_ratio = pane_ratio(v)
      vim.api.nvim_set_current_tabpage(home)
    `);
    await resize(160, 48);
    await resize(120, 40);
    await nvim.lua(
      "assert(vim.api.nvim_get_current_tabpage() == home); vim.api.nvim_set_current_tabpage(v.tab)",
    );
    await nvim.wait("return vim.api.nvim_win_get_width(v.explorer_win) == 30");
    await nvim.lua("expect_ratio(v, inactive_ratio)");
    await nvim.lua(`
      vim.api.nvim_win_set_width(v.left_win, 21)
      roundtrip_ratio = pane_ratio(v)
    `);
    for (let i = 0; i < 12; i++) {
      await resize(80, 26);
      await nvim.lua("expect_ratio(v, roundtrip_ratio)");
      await resize(120, 40);
      await nvim.lua("expect_ratio(v, roundtrip_ratio)");
    }

    await nvim.lua(`
      local win, settings = v.explorer_win, v.explorer_options
      for _, bad in ipairs({function() error('size failure') end, function() return 0 end, function() return 1.5 end, function() return 0/0 end, function() return math.huge end, function() return nil end}) do
        assert(not pcall(plugin.set_explorer, v, {width=bad}))
        assert(v.explorer_win == win and v.explorer_options == settings)
      end
      fail_size = false
      sometimes_calls = 0
      sometimes = function(ctx) sometimes_calls = sometimes_calls + 1; if fail_size then error('size failure') end return math.floor(ctx.columns/4) end
      plugin.set_explorer(v, {width=sometimes})
      fail_size = true
      failure_ratio = pane_ratio(v)
      notices = {}
    `);
    await resize(160, 48);
    await nvim.wait("return #notices == 1");
    await nvim.lua("expect_ratio(v, failure_ratio)");
    await nvim.lua(
      "failed_calls = sometimes_calls; vim.api.nvim_set_current_tabpage(home)",
    );
    await nvim.lua(
      "vim.api.nvim_set_current_tabpage(v.tab); vim.schedule(function() tab_checked = true end)",
    );
    await nvim.wait("return tab_checked");
    await nvim.lua(
      "assert(sometimes_calls == failed_calls, 'TabEnter repeated a failed size calculation without another resize')",
    );
    await resize(100, 32);
    await nvim.lua(
      "assert(sometimes_calls == failed_calls + 1 and #notices == 1 and v.alive and vim.bo[draft].modified); fail_size = false",
    );
    await nvim.lua(
      "plugin.set_explorer(v, {width=sometimes}); assert(sometimes_calls == failed_calls + 2 and vim.api.nvim_win_get_width(v.explorer_win) == 25)",
    );
    await resize(120, 40);
    await nvim.wait("return vim.api.nvim_win_get_width(v.explorer_win) == 30");
    await nvim.lua(`
      plugin.set_explorer(v, {width=24})
      vim.api.nvim_win_set_width(v.explorer_win, 28)
      plugin.set_explorer(v, {position='right'})
      assert(vim.api.nvim_win_get_width(v.explorer_win) == 28, 'Moving a numeric-size panel lost its manual width')
      numeric_ratio = pane_ratio(v)
    `);
    await resize(160, 48);
    assertEquals(await width(), 28);
    await nvim.lua("expect_ratio(v, numeric_ratio)");
    await nvim.lua(`
      wanted = 31
      adjustable = function() return wanted end
      plugin.set_explorer(v, {width=adjustable})
      local events = layout_events
      wanted = 32
      plugin.set_explorer(v, {width=adjustable})
      assert(vim.api.nvim_win_get_width(v.explorer_win) == 32 and layout_events == events + 1)
      plugin.set_explorer(v, {visible=false})
      wanted = 35
      plugin.set_explorer(v, {width=adjustable})
      plugin.set_explorer(v, {visible=true})
      assert(vim.api.nvim_win_get_width(v.explorer_win) == 35)
      local getter = vim.api.nvim_win_get_width
      local ratio = getter(v.left_win) / (getter(v.left_win) + getter(v.right_win))
      plugin.set_explorer(v, {width=dynamic_width})
      assert(math.abs(getter(v.left_win) - (getter(v.left_win) + getter(v.right_win)) * ratio) <= 1)
      plugin.set_layout(v, 'stacked')
      plugin.set_explorer(v, {position='bottom'})
      getter = vim.api.nvim_win_get_height
      vim.api.nvim_win_set_height(v.left_win, 8)
      ratio = getter(v.left_win) / (getter(v.left_win) + getter(v.right_win))
      plugin.set_explorer(v, {height=function() return 8 end})
      assert(math.abs(getter(v.left_win) - (getter(v.left_win) + getter(v.right_win)) * ratio) <= 1)
      constrained_ratio = pane_ratio(v)
      plugin.set_explorer(v, {height=function(ctx) last_height_lines = ctx.lines; return 10000 end})
    `);
    await resize(60, 16);
    await nvim.wait("return last_height_lines == 16");
    await nvim.lua(
      "local height=vim.api.nvim_win_get_height(v.explorer_win); assert(height > 0 and height <= 8)",
    );
    await resize(160, 48);
    await nvim.wait("return vim.api.nvim_win_get_height(v.explorer_win) == 24");
    await nvim.lua("expect_ratio(v, constrained_ratio)");
    await nvim.lua(`
      plugin.set_layout(v, 'side_by_side')
      plugin.set_explorer(v, {position='left', width=function() return 10000 end})
    `);
    await resize(60, 24);
    await nvim.wait("return vim.api.nvim_win_get_width(v.explorer_win) == 54");
    await resize(160, 48);
    await nvim.wait("return vim.api.nvim_win_get_width(v.explorer_win) == 154");
    await nvim.lua(
      `
      plugin.set_explorer(v, {width=dynamic_width})
      other = plugin.open({root=select(1,...),right='HEAD',file=select(2,...),explorer={visible=true,width=dynamic_width}})
    `,
      root,
      path,
    );
    await nvim.wait("return other.ready or other.error");
    await nvim.lua(
      "assert(not other.error and not vim.bo[other.right_buf].modifiable)",
    );
    await resize(120, 40);
    await nvim.wait(
      "return vim.api.nvim_win_get_width(other.explorer_win) == 30",
    );
    await nvim.lua(
      "assert(vim.api.nvim_get_current_tabpage()==other.tab); plugin.close(other); vim.api.nvim_set_current_tabpage(v.tab)",
    );
    await nvim.wait("return vim.api.nvim_win_get_width(v.explorer_win) == 30");
    await nvim.lua(`
      local replacement = function() return 29 end
      plugin.set_explorer(v, {width=function()
        plugin.set_explorer(v, {width=replacement})
        return 45
      end})
      assert(v.explorer_options.width == replacement and vim.api.nvim_win_get_width(v.explorer_win) == 29)
      plugin.set_explorer(v, {width=function() plugin.close(v); return 45 end})
      assert(not v.alive)
    `);
    await resize(160, 48);
    await nvim.lua(
      `
      plugin.close(v)
      plugin.shutdown()
      plugin.config.explorer = nil
      plugin.setup({width=33})
      v = plugin.open({root=...})
    `,
      root,
    );
    await nvim.wait("return v.ready or v.error");
    assertEquals(await width(), 33);
    await nvim.lua(
      "plugin.close(v); plugin.config.width = nil; v = plugin.open({root=...})",
      root,
    );
    await nvim.wait("return v.ready or v.error");
    assertEquals(await width(), 32);
    await resize(120, 40);
    await nvim.wait("return vim.api.nvim_win_get_width(v.explorer_win) == 24");
    nvim.capture(out, "default-responsive");
    await nvim.lua(
      `
      plugin.close(v)
      local tabs, bufs = #vim.api.nvim_list_tabpages(), #vim.api.nvim_list_bufs()
      assert(not pcall(plugin.open, {root=..., explorer={width=function() error('initial failure') end}}))
      assert(#vim.api.nvim_list_tabpages() == tabs and #vim.api.nvim_list_bufs() == bufs)
      v = plugin.open({root=..., explorer={visible=false,width=function() error('hidden failure') end}})
      assert(not pcall(plugin.toggle_explorer, v))
      assert(v.alive and not v.explorer_win)
      plugin.close(v)
      v = plugin.open({root=...,explorer={width=dynamic_width}})
      vim.api.nvim_exec_autocmds('VimResized', {})
      plugin.close(v)
    `,
      root,
    );
    await nvim.lua(
      "assert(not v.alive and not plugin.get_view(v.id)); plugin.shutdown()",
    );
  } catch (error) {
    nvim.capture(out, "failure");
    throw error;
  } finally {
    await nvim.close();
  }
  console.log(JSON.stringify({ passed: true }));
}

if (import.meta.main) await main();
