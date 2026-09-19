import { git, Nvim } from "./support.ts";
import {
  argumentsFor,
  assert,
  basename,
  equal,
  exists,
  failure,
  includes,
  join,
  json,
  lines,
  mkdir,
  now,
  range,
  read,
  remove,
  resolve,
  run as command,
  temporary as makeTemp,
  write,
} from "../scripts/lib.ts";
import { Random } from "./random.ts";

export async function settle(nvim: Nvim) {
  await nvim.wait(
    `
      return not view.alive or view.error or (
        view.ready and not view.updating and not view.selection_pending
        and not view.layout_pending and not view.inline_pending and not view.requested_layout
        and (view.layout ~= 'inline' or require('diffreel.inline').current(view)))
    `,
    15,
  );
  const state = await nvim.lua(
    "return {alive=view.alive,error=view.error,layout=view.layout,path=view.selected_path}",
  );
  assert(state["alive"] && !(state["error"]), String(state));
}

export async function revision_lines(
  root: string,
  revision: string,
  path: string,
) {
  const result = await command(["git", "show", revision + ":" + path], {
    cwd: root,
    check: false,
  });
  if ((!equal(result.code, 0))) {
    return [""];
  }
  return lines(result.stdout).length ? lines(result.stdout) : [""];
}

export async function check_content(nvim: Nvim, root: string, left: string) {
  let expected;
  await nvim.lua("require('diffreel').refresh(view)");
  await settle(nvim);
  if ((equal(left, "HEAD"))) {
    expected = await git(root, "rev-parse", "HEAD");
    await nvim.wait(
      "return view.comparison.left == " + JSON.stringify(expected),
    );
    await settle(nvim);
  } else {
    assert(equal(await nvim.lua("return view.comparison.left"), left));
  }
  const state = await nvim.lua(
    `
      local entry=view.by_path[view.selected_path]
      if not entry then return vim.empty_dict() end
      return {path=entry.path,old_path=entry.old_path,left=view.comparison.left,
        lines=vim.api.nvim_buf_get_lines(view.left_buf,0,-1,false),
        right=vim.api.nvim_buf_get_lines(view.right_buf,0,-1,false),
        modified=vim.bo[view.right_buf].modified,kind=entry.right.kind,exists=entry.right.exists}
    `,
  );
  if (!(state["path"])) {
    return undefined;
  }
  const revision = (equal(state["left"], ":0")) ? "" : state["left"];
  expected = await revision_lines(
    root,
    revision,
    (state["old_path"]) || state["path"],
  );
  assert(
    equal(state["lines"], expected),
    String({
      ["path"]: state["path"],
      ["left"]: state["left"],
      ["actual"]: state["lines"],
      ["expected"]: expected,
    }),
  );
  if (
    (!(state["modified"]) && (equal(state["kind"], "text")) && state["exists"])
  ) {
    expected = lines(read(join(root, state.path)));
    if (!expected.length) expected = [""];
    assert(
      equal(state["right"], expected),
      String({
        ["path"]: state["path"],
        ["actual"]: state["right"],
        ["expected"]: expected,
      }),
    );
  }
}

export async function run(seed: number, steps: number, output: string) {
  let actual,
    base,
    buf,
    current,
    destination,
    entries,
    existing,
    notifications,
    nvim,
    operation,
    originals,
    path,
    paths,
    root,
    source;
  let action: Record<string, unknown>;

  const rng = new Random(seed);
  const actions: Record<string, unknown>[] = [];
  const drafts: Record<number, string[]> = {};
  const closed: string[] = [];
  const views: Record<string, string> = {};
  const watch = Boolean(seed % 2);
  const statistics = equal(seed % 3, 0);
  const started = now();
  const result: Record<string, unknown> = {
    ["seed"]: seed,
    ["steps"]: steps,
    ["watch"]: watch,
    ["line_stats"]: statistics,
  };
  {
    using temp_temporary = makeTemp("seed-" + String(seed) + "-", output);
    const temporary = temp_temporary.path;
    root = resolve(temporary);
    await git(root, "init", "-qb", "main");
    paths = ["a.txt", "nested/b.txt", "nested/c.txt"];
    originals = Object.fromEntries(paths.map((path) => [basename(path), path]));
    mkdir(join(root, "nested"));
    mkdir(join(root, "renamed"));
    for (const path of paths) {
      write(
        join(root, path),
        (("header " + String(path) + "\n") +
          ((range(60)).map((i) => ("same " + String(i)))).join("\n")) + "\n",
      );
    }
    await git(root, "add", ".");
    await git(root, "commit", "-qm", "base");
    base = await git(root, "rev-parse", "HEAD");
    for (const path of paths) {
      write(
        join(root, path),
        ("saved " + String(path) + "\n") + ("context\n").repeat(60),
      );
    }
    nvim = await Nvim.create(root);
    try {
      await nvim.lua(
        `
              local watch,stats=...
              vim.g.mapleader=','
              require('diffreel').setup({watch=watch,line_stats=stats,reconcile_ms=500})
              _G.view=require('diffreel').open()
              _G.notifications={}
              vim.notify=function(message,level)
                notifications[#notifications+1]={message=message,level=level}
              end
            `,
        watch,
        statistics,
      );
      await settle(nvim);
      current = await nvim.lua("return view.id");
      views[current] = "HEAD";
      for (const step of range(steps)) {
        operation = rng.choice([
          "edit",
          "select",
          "burst",
          "layout",
          "panel",
          "disk",
          "rename",
          "index",
          "head",
          "peer",
          "switch",
          "close",
          "options",
        ]);
        action = { ["step"]: step, ["operation"]: operation };
        actions.push(action);
        if ((equal(operation, "edit"))) {
          if (
            (await nvim.lua(
              "return view.right_buf~=view.empty_buf and vim.bo[view.right_buf].buftype==''",
            ))
          ) {
            buf = await nvim.lua("return view.right_buf");
            await nvim.lua(
              "vim.api.nvim_buf_set_lines(view.right_buf,0,1,false,{...})",
              "draft seed " + String(seed) + " step " + String(step),
            );
            drafts[buf] = await nvim.lua(
              "return vim.api.nvim_buf_get_lines(view.right_buf,0,-1,false)",
            );
            action["buffer"] = buf;
          }
        } else if ((includes(["select", "burst"], operation))) {
          entries = await nvim.lua(
            "return vim.tbl_map(function(e) return e.path end,view.entries)",
          );
          if (entries.length) {
            action["path"] = rng.choice(entries);
            await nvim.lua(
              `
                          local path,burst=...
                          require('diffreel').select(view,path)
                          if burst then
                            require('diffreel').cycle_layout(view)
                            require('diffreel').refresh(view)
                            require('diffreel').cycle_layout(view)
                          end
                        `,
              action["path"],
              equal(operation, "burst"),
            );
          }
        } else if ((equal(operation, "layout"))) {
          action["layout"] = rng.choice(["side_by_side", "stacked", "inline"]);
          await nvim.lua(
            "require('diffreel').set_layout(view,...)",
            action["layout"],
          );
        } else if ((equal(operation, "panel"))) {
          Object.assign(action, {
            position: rng.choice(["left", "right", "top", "bottom"]),
            visible: rng.choice([true, false]),
          });
          await nvim.lua(
            "require('diffreel').set_explorer(view,{position=select(1,...),visible=select(2,...)})",
            action["position"],
            action["visible"],
          );
        } else if ((equal(operation, "disk"))) {
          path = rng.choice(paths);
          action["path"] = path;
          if ((equal(rng.randrange(4), 0))) {
            remove(join(root, path));
            action["deleted"] = true;
          } else {
            write(
              join(root, path),
              ("external seed " + String(seed) + " step " + String(step) +
                "\n") + ("context\n").repeat(60),
            );
          }
          await nvim.lua("require('diffreel').refresh(view)");
        } else if ((equal(operation, "rename"))) {
          existing = (paths.filter((
            path,
          ) => (exists(join(root, path)) &&
            Deno.statSync(join(root, path)).isFile)
          )).map((path) => path);
          if (existing.length) {
            source = rng.choice(existing);
            destination = source.startsWith("renamed/")
              ? originals[basename(source)]
              : ("renamed/" + basename(source));
            Deno.renameSync(join(root, source), join(root, destination));
            if ((!includes(paths, destination))) {
              paths.push(destination);
            }
            Object.assign(action, { source: source, destination: destination });
            await nvim.lua("require('diffreel').refresh(view)");
          }
        } else if ((equal(operation, "index"))) {
          await git(root, "add", "-A");
          await nvim.lua("require('diffreel').refresh(view)");
        } else if ((equal(operation, "head"))) {
          write(
            join(root, "generation.txt"),
            String(seed) + ":" + String(step) + "\n",
          );
          await git(root, "add", "generation.txt");
          await git(root, "commit", "-qm", "step " + String(step));
          await nvim.lua("require('diffreel').refresh(view)");
        } else if (
          ((equal(operation, "peer")) && (Object.keys(views).length < 4))
        ) {
          Object.assign(action, {
            left: rng.choice(["HEAD", base, ":0"]),
            layout: rng.choice(["side_by_side", "stacked", "inline"]),
          });
          await nvim.lua(
            "view=require('diffreel').open({root=view.root,left=select(1,...),layout=select(2,...)})",
            action["left"],
            action["layout"],
          );
          current = await nvim.lua("return view.id");
          views[current] = String(action.left);
        } else if ((equal(operation, "switch"))) {
          current = rng.choice(Object.keys(views));
          action["view"] = current;
          await nvim.lua(
            "view=require('diffreel').get_view(...);vim.api.nvim_set_current_tabpage(view.tab);require('diffreel').refresh(view)",
            current,
          );
        } else if ((equal(operation, "close"))) {
          closed.push(current);
          delete views[current];
          await nvim.lua("require('diffreel').close(view)");
          if (Object.keys(views).length) {
            current = rng.choice(Object.keys(views));
            await nvim.lua(
              "view=require('diffreel').get_view(...);vim.api.nvim_set_current_tabpage(view.tab);require('diffreel').refresh(view)",
              current,
            );
          } else {
            await nvim.lua(
              "view=require('diffreel').open({root=...})",
              String(root),
            );
            current = await nvim.lua("return view.id");
            views[current] = "HEAD";
          }
        } else if ((equal(operation, "options"))) {
          action["diffopt"] = rng.choice([
            "internal,filler,context:0",
            "internal,filler,context:3,linematch:40",
            "internal,filler,context:2,iwhiteall,iblank",
          ]);
          await nvim.lua("vim.o.diffopt=...", action["diffopt"]);
        }
        await settle(nvim);
        for (const [buffer, expected] of Object.entries(drafts)) {
          const buf = Number(buffer);
          assert(
            await nvim.lua("return vim.api.nvim_buf_is_valid(...)", buf),
            String({ ["lost_buffer"]: buf }),
          );
          actual = await nvim.lua(
            "return vim.api.nvim_buf_get_lines(...,0,-1,false)",
            buf,
          );
          assert(
            equal(actual, expected),
            String({
              ["draft_overwritten"]: buf,
              ["actual"]: actual,
              ["expected"]: expected,
            }),
          );
        }
        assert(
          await nvim.lua(
            "for _,id in ipairs(...) do if require('diffreel').get_view(id) then return false end end;return true",
            closed,
          ),
          String("Closed view returned"),
        );
        assert(
          await nvim.lua(
            "for _,win in ipairs(require('diffreel.windows').owned_windows(view)) do if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_tabpage(win)~=view.tab then return false end end;return true",
          ),
          String("Invalid owned window"),
        );
        assert(
          !(await nvim.lua("return vim.v.errmsg")),
          String(await nvim.lua("return vim.v.errmsg")),
        );
        if (((equal(step % 5, 0)) || (equal(step, steps - 1)))) {
          await check_content(nvim, root, views[current]);
        }
      }
      await nvim.lua(
        "for _,v in pairs(vim.tbl_extend('force',{},require('diffreel').views)) do require('diffreel').close(v) end",
      );
      assert(
        await nvim.lua(
          "return not next(require('diffreel').views) and not next(require('diffreel.lease').buffers)",
        ),
      );
      for (const [buffer, expected] of Object.entries(drafts)) {
        const buf = Number(buffer);
        assert(
          equal(
            await nvim.lua(
              "return vim.api.nvim_buf_get_lines(...,0,-1,false)",
              buf,
            ),
            expected,
          ),
        );
      }
      notifications = await nvim.lua("return notifications");
      assert(notifications.length === 0, String(notifications));
      Object.assign(result, { passed: true, notifications: notifications });
    } catch (error) {
      Object.assign(result, { passed: false, error: failure(error) });
      try {
        result["state"] = await nvim.lua(
          "return {alive=view.alive,error=view.error,path=view.selected_path,layout=view.layout,ready=view.ready,updating=view.updating,pending=view.selection_pending}",
        );
        nvim.capture(output, "seed-" + String(seed) + "-failure");
      } catch (error) {
        result["capture_error"] = String(error);
      }
    } finally {
      await nvim.close();
    }
  }
  Object.assign(result, {
    actions: actions,
    seconds: Number((now() - started).toFixed(3)),
  });
  write(
    join(output, "seed-" + String(seed) + ".json"),
    JSON.stringify(result) + "\n",
  );
  return result;
}

if (import.meta.main) {
  const args = argumentsFor({
    output: ".wadackel/qa/stateful",
    seeds: [3, 4, 17, 318],
    steps: 60,
  });
  const out = resolve(String(args.output));
  mkdir(out);
  assert(Number(args.steps) > 0);
  const results = [];
  for (const seed of args.seeds as number[]) {
    const result = await run(seed, Number(args.steps), out);
    results.push(result);
    console.log(
      JSON.stringify(Object.fromEntries(
        Object.entries(result).filter(([key]) =>
          !["actions", "notifications"].includes(key)
        ),
      )),
    );
  }
  json(join(out, "results.json"), results);
  Deno.exitCode = results.every((r) => r.passed) ? 0 : 1;
}
