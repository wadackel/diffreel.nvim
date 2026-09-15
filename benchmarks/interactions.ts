import { Nvim } from "../tests/support.ts";
import {
  argumentsFor,
  assert,
  basename,
  bytes,
  filesBelow,
  join,
  json,
  lines,
  mkdir,
  now,
  relative,
  resolve,
  ROOT,
  sha256,
  sleep,
} from "../scripts/lib.ts";
import {
  CASES,
  content,
  create,
  expected,
  Fixture,
  restore,
} from "./fixtures.ts";
import { calibrate, Clock, close as closeMetrics } from "./metrics.ts";
import {
  environment,
  measure,
  phase_end,
  prepare,
  quiet,
  Row,
  summarize,
  warm_lsp,
} from "./run.ts";

async function sourceHash(root: string) {
  const paths = ["lua", "plugin"].flatMap((name) =>
    filesBelow(join(root, name))
  ).filter((path) => path.endsWith(".lua")).sort();
  const encoder = new TextEncoder(),
    parts = paths.flatMap((
      path,
    ) => [encoder.encode(relative(root, path) + "\0"), bytes(path)]),
    data = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let offset = 0;
  for (const part of parts) {
    data.set(part, offset);
    offset += part.length;
  }
  return await sha256(data);
}
interface Options {
  source: string;
  daemon: string;
  normal: boolean;
  line_stats: boolean;
  samples: number;
  interval_ms: number;
  output: string;
}
async function run(manifest: Fixture, options: Options, clock: Clock) {
  restore(manifest);
  const nvim = await Nvim.create(manifest.root, {
    normal: options.normal,
    source: options.source,
  });
  const phases: Record<
    string,
    & { trials: Row[]; summary: ReturnType<typeof summarize> }
    & Awaited<ReturnType<typeof phase_end>>
  > = {};
  try {
    const modules = Object.fromEntries(
      filesBelow(join(options.source, "lua/diffreel")).filter((path) =>
        path.endsWith(".lua")
      ).map((
        path,
      ) => [
        relative(join(options.source, "lua"), path).slice(0, -4).replaceAll(
          "/",
          ".",
        ),
        path,
      ]),
    );
    await nvim.lua(
      `
      local modules=...
      local previous=package.loaded.diffreel
      if type(previous)=='table' and previous.shutdown then previous.shutdown() end
      for name in pairs(package.loaded) do
        if name=='diffreel' or name:match('^diffreel%.') then package.loaded[name]=nil end
      end
      for name,path in pairs(modules) do
        local file=path
        package.preload[name]=function() return assert(loadfile(file))() end
      end
      package.preload.diffreel=package.preload['diffreel.init']
    `,
      modules,
    );
    await nvim.lua(
      "local path,channel=...;assert(loadfile(path))(channel)",
      join(ROOT, "benchmarks/probe.lua"),
      nvim.channel,
    );
    const [first, second] = manifest.paths;
    await prepare(
      nvim,
      "startup",
      first,
      null,
      await expected(manifest),
      await expected(manifest, manifest.paths.map(() => 0)),
    );
    await nvim.lua("_G.diffreel_expected_explorer_headers=...", [
      " " + basename(manifest.root),
      " " + manifest.head.slice(0, 10) + " → worktree",
      "",
    ]);
    if (options.line_stats) {
      await nvim.lua("_G.diffreel_expected_line_stats=...", {
        files: Object.fromEntries(
          manifest.paths.map((path) => [path, { additions: 2, deletions: 2 }]),
        ),
        additions: 2 * manifest.changed_files,
        deletions: 2 * manifest.changed_files,
      });
    }
    await nvim.lua(
      `
      local root,daemon,line_stats=...
      require('diffreel').setup({daemon=daemon,watch=false,auto_install=false,line_stats=line_stats})
      _G.view=require('diffreel').open({root=root})
      _G.diffreel_expected_unchanged_line=2
      _G.diffreel_verify_explorer=true
    `,
      manifest.root,
      options.daemon,
      options.line_stats,
    );
    await nvim.wait(
      "return view.ready and not view.updating and diffreel_probe.matches(view)",
      45,
    );
    const loadedSource = await nvim.lua<string>(
      "return debug.getinfo(require('diffreel').open,'S').source",
    );
    assert(
      resolve(loadedSource.slice(1)) ===
        join(options.source, "lua/diffreel/init.lua"),
      loadedSource,
    );
    assert(await nvim.lua("return #view.entries") === manifest.changed_files);
    const loadedModules = await nvim.lua<Record<string, string>>(
      "return {explorer=debug.getinfo(require('diffreel.explorer').rows,'S').source,lease=debug.getinfo(require('diffreel.lease').acquire,'S').source}",
    );
    for (const [module, path] of Object.entries(loadedModules)) {
      assert(
        resolve(path.slice(1)) ===
          join(options.source, `lua/diffreel/${module}.lua`),
      );
    }
    const warmups = [];
    for (const path of [second, first]) {
      await nvim.lua("require('diffreel').select(view,...)", path);
      await nvim.wait("return view.ready and not view.selection_pending");
      if (options.normal) warmups.push(await warm_lsp(nvim, clock));
    }
    await nvim.lua(`
      _G.diffreel_interaction_left=view.left_buf
      _G.diffreel_interaction_right=view.right_buf
      _G.diffreel_interaction_finish=function(channel,token,dirty)
        assert(view.ready and not view.selection_pending and diffreel_probe.matches(view))
        assert(view.left_buf==diffreel_interaction_left and view.right_buf==diffreel_interaction_right)
        if dirty then assert(view.disk_conflict and vim.bo[view.right_buf].modified) end
        vim.rpcnotify(channel,'diffreel_bench_ready',token,{path=view.selected_path})
      end
    `);
    for (const phase of ["switch", "fold", "edit"]) {
      if (phase !== "switch") {
        await nvim.lua("require('diffreel').select(view,...)", first);
        await nvim.wait("return view.ready and not view.selection_pending");
        await nvim.lua(
          "_G.diffreel_interaction_right=view.right_buf;vim.api.nvim_set_current_win(view.explorer_win);vim.api.nvim_feedkeys('gE','xt',false)",
        );
      }
      const operation = async (trial: number, token: string) => {
        const path = phase === "switch" && trial % 2 === 0 ? second : first;
        await prepare(nvim, token, path, null);
        if (phase === "switch") {
          return () => nvim.lua("require('diffreel').select(view,...)", path);
        }
        if (phase === "fold") {
          return () =>
            nvim.lua(
              `
          local keys,closed,channel,token=...
          vim.api.nvim_feedkeys(keys,'xt',false)
          assert((view.collapsed.src==true)==closed)
          assert(#view.rows==(closed and 1 or #view.entries+1))
          diffreel_interaction_finish(channel,token,false)
        `,
              trial % 2 === 0 ? "gW" : "gE",
              trial % 2 === 0,
              nvim.channel,
              token,
            );
        }
        const data = content(0, 1000 + trial);
        await nvim.lua(
          "_G.diffreel_expected_buffer_hash=...",
          await sha256(data),
        );
        return () =>
          nvim.lua(
            `
          local lines,channel,token=...
          vim.api.nvim_set_current_win(view.right_win)
          vim.api.nvim_buf_set_lines(view.right_buf,0,-1,false,lines)
          vim.schedule(function() diffreel_interaction_finish(channel,token,true) end)
        `,
            lines(data),
            nvim.channel,
            token,
          );
      };
      for (let trial = 0; trial < 6; trial++) {
        const token = `${phase}-warmup-${trial}`;
        await measure(
          nvim,
          "rust",
          clock,
          token,
          await operation(trial, token),
        );
      }
      const before = await quiet(nvim, clock), rows = [], schedule = now();
      for (let trial = 0; trial < options.samples; trial++) {
        const due = schedule + trial * options.interval_ms / 1000;
        while (now() < due) await sleep(due - now());
        const token = `${phase}-${trial}`,
          row = await measure(
            nvim,
            "rust",
            clock,
            token,
            await operation(trial, token),
          );
        assert(row.git_spawns.total === 0, JSON.stringify(row));
        rows.push(row);
      }
      phases[phase] = {
        trials: rows,
        summary: summarize(rows),
        ...await phase_end(nvim, clock, before, rows.length),
      };
    }
    nvim.capture(
      join(options.output, "screenshots"),
      "changed-" + manifest.changed_files,
    );
    assert(await nvim.lua("return vim.bo[view.right_buf].modified"));
    return {
      changed_files: manifest.changed_files,
      fixture: manifest,
      phases,
      loaded_source: loadedSource,
      loaded_modules: loadedModules,
      lsp_warmup: warmups,
    };
  } catch (error) {
    nvim.capture(join(options.output, "screenshots"), "failure");
    throw error;
  } finally {
    await nvim.close();
    restore(manifest);
  }
}
if (import.meta.main) {
  const args = argumentsFor({
    source: ROOT,
    daemon: "",
    "daemon-compiler": "",
    fixtures: "",
    output: "",
    "changed-files": [100, 1000],
    samples: 30,
    "interval-ms": 0,
    normal: false,
    "line-stats": false,
  }, ["daemon", "daemon-compiler", "fixtures", "output"]);
  const options: Options = {
    source: resolve(String(args.source)),
    daemon: resolve(String(args.daemon)),
    output: resolve(String(args.output)),
    samples: Number(args.samples),
    interval_ms: Number(args["interval-ms"]),
    normal: Boolean(args.normal),
    line_stats: Boolean(args["line-stats"]),
  };
  assert(
    options.samples >= 1 && Number.isFinite(options.interval_ms) &&
      options.interval_ms >= 0 &&
      (args["changed-files"] as number[]).every((n) =>
        Number.isInteger(n) && n >= 2
      ),
  );
  mkdir(options.output);
  try {
    const source = await sourceHash(options.source),
      clock = await calibrate(),
      env = await environment(
        options.daemon,
        String(args["daemon-compiler"]),
        clock,
      );
    json(join(options.output, "environment.json"), {
      ...env,
      source: options.source,
      source_sha256: source,
      harness_sha256: await sha256(bytes(new URL(import.meta.url).pathname)),
      deno_lock_sha256: await sha256(bytes(join(ROOT, "deno.lock"))),
      probe_sha256: await sha256(bytes(join(ROOT, "benchmarks/probe.lua"))),
      configuration: options.normal ? "normal" : "minimal",
      backend: "rust",
      watch: false,
      input_interval_ms: options.interval_ms,
      line_stats: options.line_stats,
      source_loading:
        "Explicit frozen diffreel modules; other installed configuration retained in normal mode",
      neovim: env.nvim,
      latency_endpoint:
        "validated full diff content, entry metadata, Explorer text/highlights/footer and folds followed by attached UI flush",
      cpu_endpoint: "process-family CPU through phase quiescence",
      memory_endpoint:
        "sampled process-family RSS/footprint; not an absolute peak",
      scope:
        "warm interactions; live filesystem reconciliation, cold startup and network install excluded",
      ...(options.normal
        ? {
          normal_config_entrypoint: env.normal_config,
          normal_config_entrypoint_sha256: env.normal_config_sha256,
        }
        : {}),
    });
    for (const count of args["changed-files"] as number[]) {
      const name = "changed-" + count;
      CASES[name] = [count + 102, count];
      const manifest = await create(join(String(args.fixtures), name), name),
        result = await run(manifest, options, clock);
      json(join(options.output, name + ".json"), result);
      console.log(JSON.stringify({
        changed_files: count,
        ...Object.fromEntries(
          Object.entries(result.phases).map((
            [phase, value],
          ) => [phase, {
            p50_ms: value.summary.wall_ms.p50,
            p95_ms: value.summary.wall_ms.p95,
            cpu_ms_per_operation: value.settled_cpu_ms_per_operation,
          }]),
        ),
      }));
    }
    assert(
      await sourceHash(options.source) === source,
      "Plugin source changed during measurement",
    );
  } finally {
    closeMetrics();
  }
}
