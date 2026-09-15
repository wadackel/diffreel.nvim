import { git, Nvim } from "./support.ts";
import {
  argumentsFor,
  assert,
  denoArgs,
  equal,
  failure,
  includes,
  join,
  json,
  lines,
  mkdir,
  now,
  read,
  resolve,
  temporary,
  toFileUrl,
  write,
} from "../scripts/lib.ts";

export async function lsp_scenario(backend: string, output: string) {
  let log, messages, nvim, root;
  {
    using temp_tmp = temporary("diffreel-lsp-", undefined);
    const tmp = temp_tmp.path;
    root = resolve(tmp);
    await git(root, "init", "-q");
    write(join(root, "main.lua"), "local value = 1\nreturn value\n");
    write(
      join(root, "target.lua"),
      "local definition = true\nreturn definition\n",
    );
    await git(root, "add", ".");
    await git(root, "commit", "-qm", "baseline");
    write(join(root, "main.lua"), "local value = 2\nreturn value\n");
    nvim = await Nvim.create(root);
    log = join(join(output, "artifacts"), backend + "-lsp.jsonl");
    try {
      await nvim.lua(
        "require('diffreel').setup({backend=...,watch=false}); _G.view=require('diffreel').open()",
        backend,
      );
      await nvim.wait("return view.ready");
      await nvim.lua(
        `
              local command, target, log, root = ...
              vim.api.nvim_set_current_win(view.right_win)
              vim.lsp.start({name='diffreel-test',cmd=vim.list_extend(command,{target,log}),root_dir=root})
            `,
        denoArgs("tests/lsp_server.ts"),
        String(join(root, "target.lua")),
        String(log),
        String(root),
      );
      await nvim.wait(
        "local c=vim.lsp.get_clients({bufnr=view.right_buf}); return #c==1 and c[1].initialized",
      );
      assert(
        equal(
          await nvim.lua("return #vim.lsp.get_clients({bufnr=view.left_buf})"),
          0,
        ),
      );
      await nvim.lua(
        "vim.api.nvim_win_set_cursor(view.right_win,{1,7}); vim.lsp.buf.hover({focusable=false})",
      );
      await nvim.wait(
        `
              for _,buf in ipairs(vim.api.nvim_list_bufs()) do
                if vim.api.nvim_buf_is_loaded(buf) then
                  local text=table.concat(vim.api.nvim_buf_get_lines(buf,0,-1,false),' ')
                  if text:find('diffreel hover proof',1,true) then return true end
                end
              end
            `,
      );
      await nvim.request("nvim_command", "redraw!");
      nvim.capture(join(output, "screenshots"), backend + "-lsp-hover");
      await nvim.lua("vim.lsp.buf.definition()");
      await nvim.wait(
        "return vim.api.nvim_buf_get_name(0) == " +
          JSON.stringify(String(join(root, "target.lua"))),
      );
      assert(
        await nvim.lua("return not vim.wo[view.right_win].diff"),
        String("Definition target was diffed against unrelated source"),
      );
      write(join(root, "main.lua"), "local value = 3\nreturn value\n");
      await nvim.lua("require('diffreel').refresh(view)");
      await nvim.wait(
        "return view.by_path['main.lua'].right.content_id == vim.fn.sha256('local value = 3\\nreturn value\\n') and not view.updating",
      );
      assert(
        equal(
          await nvim.lua("return vim.api.nvim_buf_get_name(0)"),
          String(join(root, "target.lua")),
        ),
        String("Review update stole definition navigation"),
      );
      await nvim.request("nvim_input", "\u000f");
      await nvim.wait(
        ("return vim.api.nvim_buf_get_name(0) == " +
          JSON.stringify(String(join(root, "main.lua")))) +
          " and view.ready and vim.wo[view.right_win].diff",
      );
      assert(
        equal(
          await nvim.lua(
            "return vim.api.nvim_buf_get_lines(view.left_buf,0,1,false)[1]",
          ),
          "local value = 1",
        ),
      );
      messages = (lines(read(log))).map((line) => JSON.parse(line));
      assert(
        messages.some((
          m,
        ) => ((equal(m["method"], "textDocument/didOpen")) &&
          (equal(
            m["params"]["textDocument"]["uri"],
            toFileUrl(join(root, "main.lua")).href,
          )))
        ),
      );
      assert(
        !(messages.some((
          m,
        ) => ((equal(m["method"], "textDocument/didOpen")) &&
          m["params"]["textDocument"]["uri"].startsWith("diffreel:"))
        )),
      );
      return {
        ["backend"]: backend,
        ["scenario"]: "lsp-navigation",
        ["passed"]: true,
      };
    } catch (error) {
      nvim.capture(join(output, "screenshots"), backend + "-lsp-failure");
      throw error;
    } finally {
      await nvim.close();
    }
  }
}

export async function scenario(backend: string, output: string) {
  let base, current, live_ms, nvim, root, started;
  {
    using temp_tmp = temporary("diffreel-e2e-", undefined);
    const tmp = temp_tmp.path;
    root = resolve(tmp);
    await git(root, "init", "-q");
    mkdir(join(root, "src"));
    write(join(root, "src/main.lua"), "local value = 1\nreturn value\n");
    write(join(root, "src/other.lua"), "return 10\n");
    await git(root, "add", ".");
    await git(root, "commit", "-qm", "baseline");
    base = await git(root, "rev-parse", "HEAD");
    write(join(root, "src/main.lua"), "local value = 2\nreturn value\n");
    write(join(root, "src/other.lua"), "return 20\n");
    nvim = await Nvim.create(root);
    try {
      await nvim.lua(
        "require('diffreel').setup({backend=..., reconcile_ms=1000})",
        backend,
      );
      await nvim.lua(
        "_G.view = require('diffreel').open({root=...}); return view.id",
        String(root),
      );
      await nvim.wait("return view.ready and not view.updating");
      await nvim.wait(
        "return vim.api.nvim_buf_get_lines(view.left_buf,0,1,false)[1] == 'local value = 1'",
      );
      await nvim.request("nvim_command", "redraw!");
      assert(includes(nvim.text(), "local value = 1"));
      assert(includes(nvim.text(), "local value = 2"));
      nvim.capture(join(output, "screenshots"), backend + "-initial");
      started = now();
      write(join(root, "src/main.lua"), "local value = 3\nreturn value\n");
      await nvim.wait(
        "return view.ready and vim.api.nvim_buf_get_lines(view.right_buf,0,1,false)[1] == 'local value = 3'",
      );
      live_ms = (now() - started) * 1000;
      await nvim.lua("require('diffreel').next_file(view,1)");
      await nvim.wait(
        "return view.ready and view.selected_path == 'src/other.lua'",
      );
      assert(
        equal(
          await nvim.lua(
            "return vim.api.nvim_buf_get_lines(view.left_buf,0,1,false)[1]",
          ),
          "return 10",
        ),
      );
      await nvim.lua("require('diffreel').next_file(view,-1)");
      await nvim.wait(
        "return view.ready and view.selected_path == 'src/main.lua'",
      );
      await nvim.lua(
        "vim.api.nvim_buf_set_lines(view.right_buf,0,-1,false,{'local value = 99','return value'})",
      );
      write(join(root, "src/main.lua"), "local value = 4\nreturn value\n");
      await nvim.wait("return view.disk_conflict");
      assert(
        equal(
          await nvim.lua(
            "return vim.api.nvim_buf_get_lines(view.right_buf,0,1,false)[1]",
          ),
          "local value = 99",
        ),
      );
      await nvim.request("nvim_command", "redraw!");
      nvim.capture(join(output, "screenshots"), backend + "-dirty-conflict");
      await nvim.lua(
        "vim.api.nvim_buf_set_lines(view.right_buf,0,-1,false,{'local value = 4','return value'}); vim.bo[view.right_buf].modified=false",
      );
      await git(root, "add", ".");
      await git(root, "commit", "-qm", "agent change");
      current = await git(root, "rev-parse", "HEAD");
      await nvim.wait(
        ("return view.comparison and view.comparison.left == " +
          JSON.stringify(current)) + " and view.ready",
      );
      assert(equal((await nvim.lua("return view.entries")).length, 0));
      await nvim.lua(
        "_G.fixed = require('diffreel').open({root=select(1,...),left=select(2,...),right=select(3,...)})",
        String(root),
        base,
        current,
      );
      await nvim.wait("return fixed.ready");
      assert(
        equal(
          await nvim.lua(
            "return vim.api.nvim_buf_get_lines(fixed.right_buf,0,1,false)[1]",
          ),
          "local value = 4",
        ),
      );
      await nvim.request("nvim_command", "redraw!");
      nvim.capture(join(output, "screenshots"), backend + "-fixed-revisions");
      assert(!(nvim.stderr), String(nvim.stderr));
      return {
        ["backend"]: backend,
        ["passed"]: true,
        ["live_example_ms"]: live_ms,
        ["frames"]: nvim.frames,
      };
    } catch (error) {
      nvim.capture(join(output, "screenshots"), backend + "-failure");
      throw error;
    } finally {
      await nvim.close();
    }
  }
}

async function main() {
  const args = argumentsFor({ output: "", scenario: "all" }, ["output"]),
    output = resolve(String(args.output));
  mkdir(join(output, "artifacts"));
  assert(
    ["all", "basic", "lsp"].includes(String(args.scenario)),
    "Unknown scenario",
  );
  const results: Record<string, unknown>[] = [];
  const scenarios = args.scenario === "all"
    ? [scenario, lsp_scenario]
    : args.scenario === "basic"
    ? [scenario]
    : [lsp_scenario];
  for (const execute of scenarios) {
    let result;
    try {
      result = await execute("rust", output);
    } catch (error) {
      result = {
        backend: "rust",
        scenario: execute.name,
        passed: false,
        error: failure(error),
      };
    }
    results.push(result);
    console.log(JSON.stringify(result));
  }
  json(join(output, "artifacts", `e2e-${args.scenario}.json`), results);
  Deno.exitCode = results.every((r) => r.passed) ? 0 : 1;
}
if (import.meta.main) await main();
