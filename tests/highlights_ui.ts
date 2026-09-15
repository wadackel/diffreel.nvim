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
  using temp = temporary("highlight-", out);
  const root = temp.path;
  await git(root, "init", "-qb", "main");
  mkdir(join(root, "dir"));
  write(join(root, "dir/alpha.txt"), "same\nold value\n");
  await git(root, "add", ".");
  await git(root, "commit", "-qm", "base");
  write(join(root, "dir/alpha.txt"), "same\nnew value\n");
  const nvim = await Nvim.create(root, { columns: 145, rows: 35 });
  try {
    await nvim.lua(`
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
        ["M", 0xdd3388],
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
    await nvim.lua("plugin.show_help(v)");
    await flush(nvim);
    assertEquals(style(nvim, "q", "close").foreground, 0x11ccee);
    assertEquals(style(nvim, "close", "q").foreground, 0xeecc11);
    nvim.capture(out, "help");
    await nvim.lua("require('diffreel.popup').close(v); plugin.show_path(v)");
    await flush(nvim);
    assertEquals(style(nvim, root).foreground, 0xcc11aa);
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
