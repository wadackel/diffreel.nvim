import { Nvim } from "./support.ts";
import {
  argumentsFor,
  assert,
  assertEquals,
  git,
  join,
  mkdir,
  resolve,
  temporary,
  write,
} from "../scripts/lib.ts";

async function flush(nvim: Nvim) {
  const frame = nvim.frames;
  await nvim.request("nvim_command", "redraw!");
  await nvim.waitFrame(frame);
}

function style(nvim: Nvim, text: string, contains?: string) {
  for (const row of nvim.grids.get(1) ?? []) {
    const line = row.map(([cell]) => cell).join("");
    if (
      line.includes(text) && (contains === undefined || line.includes(contains))
    ) {
      return nvim.highlights[row[line.indexOf(text)][1]];
    }
  }
  throw new Error(
    `Missing visible text: ${JSON.stringify(text)}, ${
      JSON.stringify(contains)
    }\n${nvim.text()}`,
  );
}

async function main() {
  const args = argumentsFor({ output: ".wadackel/qa/highlights-ui" });
  const out = resolve(String(args.output));
  mkdir(out);
  using temp = temporary("highlight-" + "nested-".repeat(24), out);
  const root = temp.path;
  await git(root, "init", "-qb", "main");
  mkdir(join(root, "dir"));
  write(join(root, "dir/alpha.txt"), "same\nold value\n");
  write(
    join(root, "dir/filler.txt"),
    "header\nremoved only\nseparator one\nold call\nold argument\nseparator two\nfooter\n",
  );
  await git(root, "add", ".");
  await git(root, "commit", "-qm", "base");
  write(join(root, "dir/alpha.txt"), "same\nnew value\n");
  write(
    join(root, "dir/filler.txt"),
    "header\nseparator one\nnew call\nseparator two\nadded first\nadded second\nfooter\n",
  );
  const nvim = await Nvim.create(root, { columns: 145, rows: 35 });
  try {
    await nvim.lua(`
      vim.opt.fillchars:append({diff='╱'})
      vim.api.nvim_set_hl(0,'DevIconFixture',{fg=0x123abc})
      package.preload['nvim-web-devicons']=function()
        return {get_icon=function() return 'I','DevIconFixture' end}
      end
      vim.cmd.edit('dir/alpha.txt')
      _G.source=vim.api.nvim_get_current_buf()
      _G.ordinary=vim.api.nvim_get_current_win()
      vim.api.nvim_set_hl(0,'FixtureNormal',{bg=0x131721})
      vim.wo.winhighlight='Normal:FixtureNormal'
      _G.plugin=require('diffreel')
      plugin.setup({watch=false,line_stats=true,width=45})
      _G.v=plugin.open()
    `);
    await nvim.wait(
      "return v.ready and require('diffreel.line_stats').current(v) and not require('diffreel.line_stats').current(v).pending or v.error",
    );
    assert(!await nvim.lua("return v.error"));
    await flush(nvim);
    assertEquals(style(nvim, "I", "alpha.txt").foreground, 0x123abc);
    nvim.capture(out, "defaults");
    await nvim.lua(`
      plugin.setup({on_highlight=function(g)
        g.DiffreelExplorerModifiedName={fg=0xaabb11}
        g.DiffreelExplorerFileIcon={fg=0x22bbcc}
        g.DiffreelExplorerModifiedMarker={fg=0xdd3388}
        g.DiffreelExplorerStatsAdd={fg=0x44cc55}
        g.DiffreelExplorerStatsDelete={fg=0xee6644}
        g.DiffreelExplorerTitle={fg=0xaa55cc}
        g.DiffreelHelpKey={fg=0x11ccee}
        g.DiffreelHelpAction={fg=0xeecc11}
        g.DiffreelPathText={fg=0xcc11aa}
        g.DiffreelLineDelete={bg=0x352244}
        g.DiffreelInlineDeleteNumber={fg=0x66ee88,bg=0x352244}
      end})
    `);
    await flush(nvim);
    for (
      const [token, color] of [
        ["alpha.txt", 0xaabb11],
        ["I", 0x22bbcc],
        ["", 0xdd3388],
        ["+1", 0x44cc55],
        ["-1", 0xee6644],
      ] as const
    ) assertEquals(style(nvim, token, "+1 -1").foreground, color, token);
    assertEquals(style(nvim, "Changes").foreground, 0xaa55cc);
    assert(
      await nvim.lua(
        "return vim.wo[v.right_win].winhighlight:find('Normal:FixtureNormal',1,true)~=nil",
      ),
    );
    nvim.capture(out, "custom");
    await nvim.lua(
      "plugin.set_explorer(v,{width=28,status_icons={modified='変更'}})",
    );
    await flush(nvim);
    assertEquals(style(nvim, "変更", "alpha.txt").foreground, 0xdd3388);
    assertEquals(
      await nvim.lua("return vim.fn.strdisplaywidth(v.rows[#v.rows].text)"),
      27,
    );
    nvim.capture(out, "wide-status-icon");
    await nvim.lua(
      "plugin.set_explorer(v,{width=45,status_icons={modified=''}})",
    );
    await nvim.lua("plugin.show_help(v)");
    await flush(nvim);
    assertEquals(style(nvim, "q", "close").foreground, 0x11ccee);
    assertEquals(style(nvim, "close", "q").foreground, 0xeecc11);
    nvim.capture(out, "help");
    await nvim.lua("require('diffreel.popup').close(v); plugin.show_path(v)");
    await flush(nvim);
    assertEquals(
      await nvim.lua(
        "return vim.api.nvim_buf_get_lines(v.path_popup.buf,0,1,false)[1]",
      ),
      join(root, "dir/alpha.txt"),
    );
    // Searching for the full path in one screen row fails when the checkout path wraps.
    assertEquals(style(nvim, root.slice(0, 32)).foreground, 0xcc11aa);
    nvim.capture(out, "path");
    await nvim.lua(
      "require('diffreel.popup').close(v,'path_popup'); plugin.set_explorer(v,{visible=false}); plugin.setup({on_highlight=false}); plugin.set_explorer(v,{visible=true,mode='list'})",
    );
    await flush(nvim);
    assertEquals(style(nvim, "I", "alpha.txt").foreground, 0x123abc);
    await nvim.lua(
      "plugin.setup({on_highlight=function(g) g.DiffreelExplorerModifiedIcon={} end})",
    );
    await flush(nvim);
    assert(style(nvim, "I", "alpha.txt").foreground !== 0x123abc);
    await nvim.lua(`
      plugin.setup({on_highlight=function(g)
        g.DiffreelInlineDeleteNumber={fg=0x66ee88,bg=0x352244}
      end})
      plugin.set_layout(v,'stacked')
      plugin.set_layout(v,'inline')
    `);
    await nvim.wait(
      "return v.layout=='inline' and v.ready and not v.inline_pending or v.error",
    );
    assert(!await nvim.lua("return v.error"));
    await flush(nvim);
    assertEquals(style(nvim, "2-", "old value").foreground, 0x66ee88);
    nvim.capture(out, "inline");
    await nvim.lua(`
      plugin.setup({on_highlight=false})
      plugin.select(v,'dir/filler.txt')
    `);
    await nvim.wait(
      "return v.ready and v.selected_path=='dir/filler.txt' and not v.inline_pending or v.error",
    );
    assert(!await nvim.lua("return v.error"));
    for (
      const layout of ["side_by_side", "stacked", "inline", "side_by_side"]
    ) {
      await nvim.lua("plugin.set_layout(v,...)", layout);
      await nvim.wait(
        "return v.ready and not v.inline_pending or v.error",
      );
      assert(!await nvim.lua("return v.error"));
      assertEquals(await nvim.lua("return v.layout"), layout);
      await flush(nvim);
      const groups = await nvim.lua(`
        local groups={}
        for _,name in ipairs({'DiffreelLineDelete','DiffreelLineAdd','DiffreelFiller'}) do
          groups[name]=vim.api.nvim_get_hl(0,{name=name,link=false})
        end
        return groups
      `);
      assertEquals(
        style(nvim, "removed only").background,
        groups.DiffreelLineDelete.bg,
      );
      assertEquals(
        style(nvim, "added first").background,
        groups.DiffreelLineAdd.bg,
      );
      if (layout === "inline") {
        assert(
          !nvim.text().includes("╱"),
          "Inline rendered native diff filler",
        );
      } else {
        const windows = await nvim.lua(`
          local result={}
          for _,win in ipairs({v.left_win,v.right_win}) do
            result[#result+1]={position=vim.api.nvim_win_get_position(win),
              width=vim.api.nvim_win_get_width(win),height=vim.api.nvim_win_get_height(win)}
          end
          return result
        `) as { position: [number, number]; width: number; height: number }[];
        for (const { position: [top, left], width, height } of windows) {
          const filler = (nvim.grids.get(1) ?? []).slice(top, top + height)
            .flatMap((row) => row.slice(left, left + width))
            .filter(([char]) => char === "╱");
          assert(filler.length > 0, `Missing visible filler in ${layout}`);
          for (const [, id] of filler) {
            assertEquals(
              nvim.highlights[id].foreground,
              groups.DiffreelFiller.fg,
            );
            assertEquals(
              nvim.highlights[id].background,
              groups.DiffreelFiller.bg,
            );
            assert(
              !nvim.highlights[id].reverse,
              "Filler reversed the theme colors",
            );
          }
        }
      }
      nvim.capture(out, "filler-" + layout);
    }
    await nvim.lua(
      "vim.api.nvim_buf_set_lines(source,0,1,false,{'unsaved'});plugin.close(v);assert(vim.bo[source].modified);assert(vim.wo[ordinary].winhighlight=='Normal:FixtureNormal')",
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
