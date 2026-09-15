import { git, Nvim } from "./support.ts";
import {
  argumentsFor,
  equal,
  join,
  mkdir,
  range,
  remove,
  resolve,
  temporary,
  write,
} from "../scripts/lib.ts";

export async function fixture(root: string) {
  let after, before;
  for (const folder of ["src", "src/format", "tests", "docs"]) {
    mkdir(join(root, folder));
  }
  before = `export interface ParserOptions {
  strict: boolean;
  maxDepth: number;
}

const defaults: ParserOptions = {
  strict: false,
  maxDepth: 32,
};

export function parse(input: string, options = defaults) {
  const tokens = input.trim().split(" ");
  if (tokens.length > options.maxDepth) {
    throw new Error("Too many tokens");
  }
  return tokens.filter(Boolean);
}

function legacyFallback(input: string) {
  return input.split(",");
}

`;
  for (const i of range(12)) {
    before += "export function normalize" + String(i) +
      "(value: string) {\n  return value.trim();\n}\n\n";
  }
  before +=
    'export function formatResult(tokens: string[]) {\n  return tokens.join(" ");\n}\n';
  write(join(root, "src/parser.ts"), before);
  write(join(root, "src/format/output.ts"), 'export const separator = ",";\n');
  write(join(root, "docs/legacy.md"), "Legacy parser options\n");
  await git(root, "init", "-q");
  await git(root, "add", ".");
  await git(root, "commit", "-qm", "baseline");
  after = before.replace("strict: false", "strict: true").replace(
    "maxDepth: 32",
    "maxDepth: 64",
  );
  after = after.replace(
    '  const tokens = input.trim().split(" ");',
    '  const normalized = input.normalize("NFC");\n  const tokens = normalized.trim().split(/\\s+/);',
  );
  after = after.replace(
    'function legacyFallback(input: string) {\n  return input.split(",");\n}\n\n',
    "",
  );
  after = after.replace('tokens.join(" ")', 'tokens.join(" · ")');
  write(join(root, "src/parser.ts"), after);
  write(
    join(root, "src/format/output.ts"),
    'export const separator = " · ";\n',
  );
  remove(join(root, "docs/legacy.md"));
  write(
    join(root, "tests/parser_test.ts"),
    'import { parse } from "../src/parser";\n\nconsole.assert(parse("hello world").length === 2);\n',
  );
}

export async function capture(
  root: string,
  output: string,
  viewer: string,
  label: string,
  columns: number,
) {
  let info;
  const nvim = await Nvim.create(root, {
    normal: true,
    columns: columns,
    rows: 40,
  });
  try {
    await nvim.lua(
      "vim.api.nvim_cmd({cmd='edit',args={...}}, {})",
      String(join(root, "src/parser.ts")),
    );
    if ((equal(viewer, "diffreel"))) {
      await nvim.request("nvim_command", "Diffreel");
      await nvim.wait(
        "_G.view=require('diffreel').get_current();return view and view.ready",
      );
      await nvim.lua("require('diffreel').select(view,'src/parser.ts')");
      await nvim.wait(
        "return view.ready and view.selected_path=='src/parser.ts'",
      );
      await nvim.lua(
        `
              for _,w in ipairs({view.left_win,view.right_win})do
                assert(vim.wo[w].number and vim.wo[w].foldcolumn=='1')
                assert(vim.wo[w].winhighlight~='' and vim.wo[w].winbar~='')
                vim.api.nvim_win_call(w,function()
                  assert(vim.fn.diff_hlID(1,1)==0,'Unchanged header is highlighted')
                  assert(vim.fn.foldclosed(40)>0,'Unchanged context is expanded')
                end)
              end
              local selected=false
              for _,mark in ipairs(vim.api.nvim_buf_get_extmarks(view.explorer_buf,-1,0,-1,{details=true}))do
                local row=view.rows[mark[2]-2]
                if row and row.path=='src/parser.ts' and mark[4].line_hl_group then selected=true end
              end
              assert(selected,'Selected file has no persistent highlight')
            `,
      );
    } else if ((equal(viewer, "diffview"))) {
      await nvim.lua(
        "vim.opt.rtp:prepend(vim.fn.stdpath('data')..'/lazy/diffview.nvim');require('diffview').setup({enhanced_diff_hl=true,view={default={winbar_info=true}},file_panel={win_config={width=32}}});vim.cmd('runtime plugin/diffview.lua')",
      );
      await nvim.request(
        "nvim_command",
        "DiffviewOpen --selected-file=src/parser.ts",
      );
      await nvim.wait(
        "local count=0;for _,w in ipairs(vim.api.nvim_tabpage_list_wins(0))do if vim.wo[w].diff and vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w),0,1,false)[1]=='export interface ParserOptions {' then count=count+1 end end;return count==2",
        20,
      );
    } else {
      await nvim.request("nvim_command", "CodeDiff");
      await nvim.wait(
        "local s=require('codediff.ui.lifecycle').get_session(vim.api.nvim_get_current_tabpage());return s and s.stored_diff_result and vim.api.nvim_buf_get_lines(s.modified_bufnr,0,1,false)[1]=='export interface ParserOptions {'",
        20,
      );
    }
    await nvim.request("nvim_command", "redraw!");
    nvim.capture(join(output, "screenshots"), label);
    info = await nvim.lua(
      `
          local result={diffopt=vim.o.diffopt,windows={}}
          for _,w in ipairs(vim.api.nvim_tabpage_list_wins(0))do
            result.windows[#result.windows+1]={name=vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)),
              diff=vim.wo[w].diff,winhighlight=vim.wo[w].winhighlight,foldlevel=vim.wo[w].foldlevel,
              foldenable=vim.wo[w].foldenable,foldcolumn=vim.wo[w].foldcolumn,winbar=vim.wo[w].winbar}
          end
          return result
        `,
    );
    write(
      join(join(output, "artifacts"), label + ".json"),
      JSON.stringify(info),
    );
    return info;
  } finally {
    await nvim.close();
  }
}
if (import.meta.main) {
  const args = argumentsFor({
    output: "",
    label: "diffreel-after",
    references: false,
    columns: 160,
  }, ["output"]);
  const out = resolve(String(args.output));
  mkdir(join(out, "artifacts"));
  using temp = temporary("diffreel-display-");
  await fixture(temp.path);
  await capture(
    temp.path,
    out,
    "diffreel",
    String(args.label),
    Number(args.columns),
  );
  if (args.references) {
    for (const viewer of ["diffview", "codediff"]) {
      await capture(
        temp.path,
        out,
        viewer,
        viewer + "-reference",
        Number(args.columns),
      );
    }
  }
  console.log(JSON.stringify({ passed: true, output: out }));
}
