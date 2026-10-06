import { assertEquals } from "@std/assert";
import { git, Nvim } from "./support.ts";
import {
  argumentsFor,
  join,
  mkdir,
  resolve,
  temporary,
  write,
} from "../scripts/lib.ts";

function content(tag: string, added: string[] = []) {
  const lines = Array.from(
    { length: 200 },
    (_, index) =>
      `${(index + 1) % 7 === 0 ? tag : "same"} ${
        String(index + 1).padStart(3, "0")
      } ${"abcdefghij".repeat(25)}`,
  );
  lines.splice(49, 0, ...added);
  return lines.join("\n") + "\n";
}

async function main() {
  const args = argumentsFor({ output: ".wadackel/qa/pane-binding" });
  const out = resolve(String(args.output));
  mkdir(out);
  using fixture = temporary("pane-binding-", out);
  const root = fixture.path;
  await git(root, "init", "-qb", "main");
  write(join(root, "a.txt"), content("old"));
  write(join(root, "b.txt"), content("old"));
  write(
    join(root, "c.txt"),
    content("old").split("\n").map((line) =>
      line.startsWith("old") ? line.slice(0, 7) : line
    ).join("\n"),
  );
  await git(root, "add", ".");
  await git(root, "commit", "-qm", "base");
  write(join(root, "a.txt"), content("new"));
  write(join(root, "b.txt"), content("new", ["added", "added", "added"]));
  write(join(root, "c.txt"), content("new"));
  const nvim = await Nvim.create(root, { columns: 140, rows: 40 });
  const views = () =>
    nvim.lua<Record<string, number>[]>(`
      local result = {}
      for _, win in ipairs({v.left_win, v.right_win}) do
        local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
        result[#result + 1] = {topline = view.topline, leftcol = view.leftcol}
      end
      return result
    `);
  const settled = () =>
    nvim.wait("return v.error or (v.ready and not v.layout_pending)");
  const select = async (path: string) => {
    await nvim.lua("plugin.select(v, ...)", path);
    await nvim.wait(
      `return v.error or (v.ready and v.selected_path == ${
        JSON.stringify(path)
      })`,
    );
    await settled();
  };
  const wheel = async (pane: string, direction: string, count = 1) => {
    const [row, col] = await nvim.lua<number[]>(
      "return vim.api.nvim_win_get_position(v[... .. '_win'])",
      pane,
    );
    for (let index = 0; index < count; index++) {
      await nvim.request(
        "nvim_input_mouse",
        "wheel",
        direction,
        "",
        0,
        row + 5,
        col + 12,
      );
    }
  };
  // The right side of b.txt holds three more lines above the scrolled region.
  const bound = async (label: string, offset: number, moved?: string) => {
    await nvim.wait(
      `
      local left = vim.api.nvim_win_call(v.left_win, vim.fn.winsaveview)
      local right = vim.api.nvim_win_call(v.right_win, vim.fn.winsaveview)
      return left.leftcol == right.leftcol and right.topline - left.topline == ${offset}
    `,
      3,
    ).catch(async (error) => {
      throw new Error(
        `${label}: panes diverged ${
          JSON.stringify(await views())
        }\n${error.message}`,
      );
    });
    if (!moved) return;
    const [left, right] = await views();
    const source = moved === "left" ? left : right;
    if (source.topline === 1 && source.leftcol === 0) {
      throw new Error(`${label}: the scrolled pane returned to the origin`);
    }
  };
  try {
    await nvim.lua(
      `
      plugin = require('diffreel')
      plugin.setup({watch=false})
      v = plugin.open({root=...})
    `,
      root,
    );
    await settled();
    for (const layout of ["side_by_side", "stacked"]) {
      await nvim.lua("plugin.set_layout(v, ...)", layout);
      await settled();
      for (const focus of ["right", "left", "explorer"]) {
        for (const pane of ["left", "right"]) {
          if (pane === focus) continue;
          const label = `${layout}, focus ${focus}, wheel over ${pane}`;
          await select("b.txt");
          await select("a.txt");
          await nvim.lua(
            "vim.api.nvim_set_current_win(v[... .. '_win'])",
            focus,
          );
          await wheel(pane, "right", 2);
          await bound(label + " horizontally", 0, pane);
          await wheel(pane, "down", 3);
          await bound(label + " vertically", 0, pane);
          await select("b.txt");
          await nvim.lua(
            "vim.api.nvim_set_current_win(v[... .. '_win'])",
            focus,
          );
          await wheel(pane, "down", 30);
          await bound(label + " past added lines", 3, pane);
          assertEquals(
            await nvim.lua("return vim.api.nvim_get_current_win()"),
            await nvim.lua("return v[... .. '_win']", focus),
          );
        }
      }
    }
    for (const layout of ["side_by_side", "stacked"]) {
      await nvim.lua("plugin.set_layout(v, ...)", layout);
      await settled();
      await select("a.txt");
      await select("c.txt");
      await nvim.lua("vim.api.nvim_set_current_win(v.right_win)");
      for (const keys of ["7G$", "j", "k0", "200|", "j", "7G$"]) {
        await nvim.request("nvim_input", keys);
        await bound(
          `${layout}, uneven lines, ${keys}`,
          0,
          keys === "k0" ? undefined : "right",
        );
      }
      await nvim.lua("vim.api.nvim_set_current_win(v.left_win)");
      await nvim.request("nvim_input", "zL");
      await bound(`${layout}, uneven lines, short side`, 0, "left");
      await nvim.lua("vim.api.nvim_set_current_win(v.right_win)");
      await nvim.request("nvim_input", "$");
      await bound(`${layout}, uneven lines, back on the long side`, 0, "right");
      assertEquals((await views())[1].leftcol > 100, true);
    }
    await nvim.lua("vim.api.nvim_set_current_win(v.right_win)");
    await select("a.txt");
    await nvim.request("nvim_input", "5GA");
    await wheel("left", "right", 2);
    await bound("insert mode", 0, "left");
    assertEquals(await nvim.lua("return vim.fn.mode()"), "i");
    await nvim.request("nvim_input", "<Esc>ggVj");
    await wheel("left", "down", 3);
    await bound("visual mode", 0, "left");
    assertEquals(await nvim.lua("return vim.fn.mode()"), "V");
    await nvim.request("nvim_input", "<Esc>");
    await nvim.lua("plugin.close(v)");
    write(join(out, "result.json"), JSON.stringify({ passed: true }) + "\n");
  } finally {
    nvim.capture(out, "final");
    await nvim.close();
  }
}

if (import.meta.main) await main();
