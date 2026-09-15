import { Nvim, PLUGIN } from "../tests/support.ts";
import {
  argumentsFor,
  assert,
  bytes,
  exists,
  invocation,
  join,
  json,
  lines,
  mkdir,
  now,
  relative,
  resolve,
  run as command,
  sha256,
  sleep,
  write,
} from "../scripts/lib.ts";
import {
  CASES,
  content,
  create,
  expected,
  Fixture,
  restore,
} from "./fixtures.ts";
import {
  calibrate,
  Clock,
  close as closeMetrics,
  Sample,
  sample,
} from "./metrics.ts";

export async function source_hash() {
  const paths: string[] = [];
  function visit(directory: string) {
    for (const entry of Deno.readDirSync(directory)) {
      const path = join(directory, entry.name);
      if (entry.isDirectory) visit(path);
      else if (entry.isFile && /\.(lua|rs|ts|sh)$/.test(path)) paths.push(path);
    }
  }
  for (
    const directory of [
      "lua",
      "plugin",
      "daemon/src",
      "benchmarks",
      "tests",
      "scripts",
    ]
  ) visit(join(PLUGIN, directory));
  paths.push(
    ...[
      "daemon/Cargo.toml",
      "daemon/Cargo.lock",
      "daemon/build.rs",
      "distribution.json",
      "deno.json",
      "deno.lock",
      ".deno-version",
    ].map((name) => join(PLUGIN, name)),
  );
  const encoder = new TextEncoder(),
    parts = paths.sort().flatMap((
      path,
    ) => [encoder.encode(relative(PLUGIN, path) + "\0"), bytes(path)]),
    data = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    data.set(part, offset);
    offset += part.length;
  }
  return await sha256(data);
}
export async function prepare(
  nvim: Nvim,
  token: string,
  path: string,
  line: string | null,
  hashes: Record<string, string> | null = null,
  leftHashes: Record<string, string> | null = null,
) {
  await nvim.lua(
    `
    local token,path,line,hashes,left_hashes = ...
    _G.diffreel_token, _G.diffreel_expected_path, _G.diffreel_expected_line = token,path,line
    if hashes ~= vim.NIL then _G.diffreel_expected_hashes = hashes end
    if left_hashes ~= vim.NIL then _G.diffreel_expected_left_hashes = left_hashes end
  `,
    token,
    path,
    line,
    hashes,
    leftHashes,
  );
}
type Counts = { backend: number; editor: number; total: number };
async function counts(nvim: Nvim, _backend: string): Promise<Counts> {
  await nvim.lua(
    "_G.diffreel_counts=nil;view.manager.backend:request('debug/metrics',{},function(err,result)_G.diffreel_counts=err and {error=err} or result end)",
  );
  const result = await nvim.wait("return _G.diffreel_counts");
  assert(!result.error, result.error);
  const editor = await nvim.lua<number>("return diffreel_probe.count");
  return {
    backend: result.git_spawns,
    editor,
    total: editor + result.git_spawns,
  };
}
export interface Row {
  wall_ms: number;
  cpu_ms: number;
  started_at: number;
  write_ms: number | null;
  rss_bytes: number;
  footprint_bytes: number;
  git_spawns: Counts;
  processes: Sample["processes"];
  trial?: number;
  editor_startup_ms?: number;
}
export async function measure(
  nvim: Nvim,
  backend: string,
  clock: Clock,
  token: string,
  action: () => unknown | Promise<unknown>,
  initial = false,
): Promise<Row> {
  const beforeCounts = initial
      ? { backend: 0, editor: 0, total: 0 }
      : await counts(nvim, backend),
    before = await sample(nvim.process.pid, clock);
  let started = now(), writeMs: number | null = null;
  const result = await action();
  if (
    result && typeof result === "object" && "completed_at" in result &&
    "started_at" in result
  ) {
    writeMs = (Number(result.completed_at) - Number(result.started_at)) * 1000;
    started = Number(result.completed_at);
  }
  const elapsed = await nvim.readyFrame(token, started, 45),
    after = await sample(nvim.process.pid, clock),
    afterCounts = await counts(nvim, backend);
  return {
    wall_ms: elapsed,
    cpu_ms: after.cpu_ms - before.cpu_ms,
    started_at: started,
    write_ms: writeMs,
    rss_bytes: after.rss_bytes,
    footprint_bytes: after.footprint_bytes,
    git_spawns: {
      backend: afterCounts.backend - beforeCounts.backend,
      editor: afterCounts.editor - beforeCounts.editor,
      total: afterCounts.total - beforeCounts.total,
    },
    processes: after.processes,
  };
}
export async function quiet(nvim: Nvim, clock: Clock, timeout = 30) {
  let before = await sample(nvim.process.pid, clock), last = now(), stable = 0;
  const deadline = last + timeout;
  const identities = (value: Sample) =>
    JSON.stringify(value.processes.map((p) => [p.pid, p.start]));
  while (now() < deadline) {
    await sleep(0.1);
    const after = await sample(nvim.process.pid, clock),
      current = now(),
      delta = after.cpu_ms - before.cpu_ms;
    if (
      identities(before) === identities(after) && delta >= 0 &&
      delta < (current - last) * 100
    ) { if (++stable >= 3) return after; } else stable = 0;
    before = after;
    last = current;
  }
  throw new Error("Process family did not become idle");
}
export async function warm_lsp(nvim: Nvim, clock: Clock) {
  const started = now();
  await nvim.wait(
    "local clients=vim.lsp.get_clients({bufnr=view.right_buf,name='vtsls'});return #clients>0 and clients[1].initialized",
    30,
  );
  await nvim.lua(`
    _G.diffreel_hover=nil
    local client=vim.lsp.get_clients({bufnr=view.right_buf,name='vtsls'})[1]
    client:request('textDocument/hover',{
      textDocument={uri=vim.uri_from_bufnr(view.right_buf)},position={line=0,character=13}
    },function(err,value)
      _G.diffreel_hover={ok=not err and value~=nil and value~=vim.NIL, result=value}
    end,view.right_buf)
  `);
  const result = await nvim.wait("return _G.diffreel_hover", 30);
  assert(result.ok, "The real vtsls hover request failed");
  await quiet(nvim, clock);
  return { milliseconds: (now() - started) * 1000, hover: result };
}
export async function phase_end(
  nvim: Nvim,
  clock: Clock,
  before: Sample,
  count: number,
) {
  const after = await quiet(nvim, clock);
  return {
    settled_cpu_ms: after.cpu_ms - before.cpu_ms,
    settled_cpu_ms_per_operation: (after.cpu_ms - before.cpu_ms) / count,
    settled_rss_bytes: after.rss_bytes,
  };
}
export function summarize(rows: Row[]) {
  assert(rows.length > 0, "Cannot summarize an empty sample");
  const metric = (
    name: "wall_ms" | "cpu_ms" | "rss_bytes" | "footprint_bytes",
  ) => {
    const values = rows.map((row) => row[name]).sort((a, b) => a - b),
      mid = Math.floor(values.length / 2);
    return {
      p50: values.length % 2
        ? values[mid]
        : (values[mid - 1] + values[mid]) / 2,
      p95: values[Math.max(0, Math.ceil(values.length * 0.95) - 1)],
      max: values.at(-1)!,
    };
  };
  return {
    samples: rows.length,
    wall_ms: metric("wall_ms"),
    cpu_ms: metric("cpu_ms"),
    rss_bytes: metric("rss_bytes"),
    footprint_bytes: metric("footprint_bytes"),
    backend_git_spawns: rows.reduce((n, r) => n + r.git_spawns.backend, 0),
    total_git_spawns: rows.reduce((n, r) => n + r.git_spawns.total, 0),
  };
}
interface Options {
  daemon: string;
  output: string;
  samples: number;
  cold_samples: number;
  live_samples: number;
  live_interval_ms: number;
  idle_seconds: number;
}
async function setup_session(
  manifest: Fixture,
  backend: string,
  normal: boolean,
  options: Options,
  clock: Clock,
  token: string,
): Promise<[Nvim, Row]> {
  const boot = now(),
    nvim = await Nvim.create(manifest.root, { normal }),
    startupMs = (now() - boot) * 1000;
  try {
    await nvim.lua(
      "local path,channel=...; assert(loadfile(path))(channel)",
      join(PLUGIN, "benchmarks/probe.lua"),
      nvim.channel,
    );
    await nvim.lua("_G.diffreel_expected_unchanged_line=2");
    await prepare(
      nvim,
      token,
      manifest.paths[0],
      lines(content(0, manifest.versions[0]))[0],
      await expected(manifest),
      await expected(manifest, manifest.paths.map(() => 0)),
    );
    const left = manifest.case === "M" ? manifest.left : "HEAD";
    const row = await measure(
      nvim,
      backend,
      clock,
      token,
      () =>
        nvim.lua(
          "local config,root,left=...;require('diffreel').setup(config);_G.view=require('diffreel').open({root=root,left=left})",
          { backend, watch: true, daemon: options.daemon },
          manifest.root,
          left,
        ),
      true,
    );
    row.editor_startup_ms = startupMs;
    assert(await nvim.lua("return #view.entries") === manifest.changed_files);
    return [nvim, row];
  } catch (error) {
    nvim.capture(
      join(options.output, "screenshots"),
      backend + "-setup-failure",
    );
    await nvim.close();
    throw error;
  }
}
async function close_view(nvim: Nvim, backend: string) {
  await nvim.lua("if view.alive then require('diffreel').close(view) end");
  await counts(nvim, backend);
}
async function choose(nvim: Nvim, path: string) {
  await nvim.lua(
    "vim.api.nvim_set_current_tabpage(view.tab); require('diffreel').select(view,...)",
    path,
  );
  await nvim.wait(
    "return view.ready and not view.updating and view.selected_path == " +
      JSON.stringify(path),
  );
}
async function idle_sample(
  nvim: Nvim,
  backend: string,
  clock: Clock,
  seconds: number,
  visible: boolean,
) {
  if (!visible) {
    await nvim.lua("vim.api.nvim_set_current_tabpage(view.return_tab)");
    await counts(nvim, backend);
  }
  const beforeCounts = await counts(nvim, backend),
    before = await sample(nvim.process.pid, clock),
    started = now();
  while (now() - started < seconds) {
    await sleep(Math.min(0.25, seconds - (now() - started)));
  }
  const after = await sample(nvim.process.pid, clock),
    afterCounts = await counts(nvim, backend);
  if (!visible) {
    assert(
      afterCounts.backend === beforeCounts.backend,
      "Hidden backend still runs Git",
    );
  } else if (seconds >= 31) {
    assert(
      afterCounts.backend > beforeCounts.backend,
      "Visible reconciliation did not run",
    );
  }
  return {
    seconds: now() - started,
    cpu_ms: after.cpu_ms - before.cpu_ms,
    git_spawns: {
      backend: afterCounts.backend - beforeCounts.backend,
      editor: afterCounts.editor - beforeCounts.editor,
      total: afterCounts.total - beforeCounts.total,
    },
    rss_bytes: after.rss_bytes,
  };
}
async function run_fixture(
  manifest: Fixture,
  normal: boolean,
  options: Options,
  clock: Clock,
) {
  const backend = "rust",
    context = normal ? "normal" : "minimal",
    phases = {
      cold: [] as Row[],
      warm_open: [] as Row[],
      switch: [] as Row[],
      live: [] as Row[],
    };
  const totals: Record<string, Awaited<ReturnType<typeof phase_end>>> = {},
    extra: Record<string, unknown> = {};
  const [first, second] = manifest.paths,
    left = manifest.case === "M" ? manifest.left : "HEAD";
  let nvim: Nvim | undefined;
  try {
    restore(manifest);
    for (let trial = 0; trial < options.cold_samples; trial++) {
      const [editor, row] = await setup_session(
        manifest,
        backend,
        normal,
        options,
        clock,
        `cold-${trial}`,
      );
      nvim = editor;
      row.trial = trial;
      phases.cold.push(row);
      if (trial === options.cold_samples - 1) {
        nvim.capture(
          join(options.output, "screenshots"),
          `${manifest.case}-${backend}-${context}`,
        );
      }
      await nvim.close();
      nvim = undefined;
    }
    [nvim] = await setup_session(
      manifest,
      backend,
      normal,
      options,
      clock,
      "warmup",
    );
    if (normal) extra.lsp_warmup = await warm_lsp(nvim, clock);
    await choose(nvim, second);
    if (normal) await warm_lsp(nvim, clock);
    await choose(nvim, first);
    await close_view(nvim, backend);
    let before = await quiet(nvim, clock);
    for (let trial = 0; trial < options.samples; trial++) {
      const token = `open-${trial}`;
      await prepare(
        nvim,
        token,
        first,
        lines(content(0, manifest.versions[0]))[0],
        await expected(manifest),
      );
      const row = await measure(
        nvim,
        backend,
        clock,
        token,
        () =>
          nvim!.lua(
            "_G.view=require('diffreel').open({root=select(1,...),left=select(2,...)})",
            manifest.root,
            left,
          ),
      );
      assert(row.git_spawns.backend === 0, JSON.stringify(row));
      row.trial = trial;
      phases.warm_open.push(row);
      await close_view(nvim, backend);
    }
    totals.warm_open = await phase_end(nvim, clock, before, options.samples);
    await nvim.lua(
      "_G.view=require('diffreel').open({root=select(1,...),left=select(2,...)})",
      manifest.root,
      left,
    );
    await nvim.wait("return view.ready and not view.updating");
    before = await quiet(nvim, clock);
    for (let trial = 0; trial < options.samples; trial++) {
      const index = trial % 2 === 0 ? 1 : 0,
        path = manifest.paths[index],
        token = `switch-${trial}`;
      await prepare(
        nvim,
        token,
        path,
        lines(content(index, manifest.versions[index]))[0],
        await expected(manifest),
      );
      const row = await measure(
        nvim,
        backend,
        clock,
        token,
        () => nvim!.lua("require('diffreel').select(view,...)", path),
      );
      assert(row.git_spawns.backend === 0, JSON.stringify(row));
      row.trial = trial;
      phases.switch.push(row);
    }
    totals.switch = await phase_end(nvim, clock, before, options.samples);
    await nvim.close();
    nvim = undefined;
    restore(manifest);
    [nvim] = await setup_session(
      manifest,
      backend,
      normal,
      options,
      clock,
      "live-warmup",
    );
    if (normal) await warm_lsp(nvim, clock);
    before = await quiet(nvim, clock);
    const schedule = now();
    for (let trial = 0; trial < options.live_samples; trial++) {
      const due = schedule + trial * options.live_interval_ms / 1000;
      while (now() < due) await sleep(due - now());
      const versions = manifest.versions.map((version) =>
          version + 100 + trial
        ),
        token = `live-${trial}`;
      await prepare(
        nvim,
        token,
        first,
        lines(content(0, versions[0]))[0],
        await expected(manifest, versions),
      );
      const row = await measure(nvim, backend, clock, token, () => {
        const started_at = now();
        for (const index of [...manifest.paths.keys()].slice(1).concat(0)) {
          write(
            join(manifest.root, manifest.paths[index]),
            content(index, versions[index]),
          );
        }
        return { started_at, completed_at: now() };
      });
      row.trial = trial;
      phases.live.push(row);
    }
    totals.live = await phase_end(nvim, clock, before, options.live_samples);
    extra.clients = await nvim.lua(
      "local result={};for _,client in ipairs(vim.lsp.get_clients({bufnr=view.right_buf}))do result[#result+1]={name=client.name,initialized=client.initialized}end;return result",
    );
    if (options.idle_seconds && manifest.case === "XL") {
      for (const visible of [true, false]) {
        extra[visible ? "visible_idle" : "hidden_idle"] = await idle_sample(
          nvim,
          backend,
          clock,
          options.idle_seconds,
          visible,
        );
      }
    }
    const summary = Object.fromEntries(
      Object.entries(phases).map((
        [name, rows],
      ) => [name, { ...summarize(rows), ...totals[name] }]),
    );
    return {
      case: manifest.case,
      backend,
      context,
      fixture: manifest,
      ...phases,
      phase_totals: totals,
      order: "cold, warm open, switch, live, idle",
      live_interval_ms: options.live_interval_ms,
      ...extra,
      summary,
    };
  } catch (error) {
    nvim?.capture(
      join(options.output, "screenshots"),
      `${manifest.case}-${backend}-${context}-failure`,
    );
    throw error;
  } finally {
    await nvim?.close();
    restore(manifest);
  }
}
export async function environment(
  daemon: string,
  compiler: string,
  clock: Clock,
) {
  const normal = join(
    Deno.env.get("XDG_CONFIG_HOME") ?? join(Deno.env.get("HOME")!, ".config"),
    Deno.env.get("NVIM_APPNAME") ?? "nvim",
    "init.lua",
  );
  return {
    source_sha256: await source_hash(),
    clock,
    platform: `${Deno.build.os}-${Deno.build.arch}`,
    deno: Deno.version,
    git: (await command(["git", "--version"])).stdout.trim(),
    nvim: lines((await command(["nvim", "--version"])).stdout)[0],
    local_rustc: (await command(["rustc", "--version"])).stdout.trim(),
    daemon_compiler: compiler,
    daemon,
    daemon_sha256: await sha256(bytes(daemon)),
    command: invocation(),
    cwd: Deno.cwd(),
    cpu: (await command(["sysctl", "-n", "machdep.cpu.brand_string"])).stdout
      .trim(),
    ram_bytes: Number((await command(["sysctl", "-n", "hw.memsize"])).stdout),
    normal_config: normal,
    normal_config_sha256: exists(normal) ? await sha256(bytes(normal)) : null,
  };
}
if (import.meta.main) {
  const args = argumentsFor({
    fixtures: "",
    output: "",
    samples: 30,
    "cold-samples": 3,
    "live-samples": 10,
    "live-interval-ms": 1000,
    cases: Object.keys(CASES),
    contexts: ["minimal", "normal"],
    "idle-seconds": 32,
    daemon: "",
    "daemon-compiler": "",
  }, ["fixtures", "output", "daemon", "daemon-compiler"]);
  const options: Options = {
    output: resolve(String(args.output)),
    daemon: resolve(String(args.daemon)),
    samples: Number(args.samples),
    cold_samples: Number(args["cold-samples"]),
    live_samples: Number(args["live-samples"]),
    live_interval_ms: Number(args["live-interval-ms"]),
    idle_seconds: Number(args["idle-seconds"]),
  };
  assert(
    Math.min(
      options.samples,
      options.cold_samples,
      options.live_samples,
      options.live_interval_ms,
    ) > 0,
  );
  mkdir(join(options.output, "artifacts"));
  try {
    const clock = await calibrate(),
      env = {
        ...await environment(
          options.daemon,
          String(args["daemon-compiler"]),
          clock,
        ),
        latency_endpoint:
          "validated DiffreelReady followed by attached UI grid flush reception",
        live_latency_start: "completion of last file write in the batch",
        cpu_primary:
          "process-family CPU over entire fixed-input-rate phase plus quiescence; startup warmed via real hover",
        cpu_per_frame:
          "secondary diagnostic only; asynchronous LSP work may finish after the frame",
        memory_endpoint:
          "sum RSS/physical footprint sampled at operation boundaries; peak is observed",
        swap: "disabled with -n for isolated fixture sessions",
      };
    json(join(options.output, "artifacts/environment.json"), env);
    const summaries = [];
    for (const name of args.cases as string[]) {
      const manifest = await create(join(String(args.fixtures), name), name);
      for (const context of args.contexts as string[]) {
        assert(["minimal", "normal"].includes(context));
        console.log(JSON.stringify({ starting_fixture: name, context }));
        const result = await run_fixture(
            manifest,
            context === "normal",
            options,
            clock,
          ),
          label = `${name}-rust-${context}`;
        json(join(options.output, "artifacts", label + ".json"), result);
        summaries.push({
          case: name,
          backend: "rust",
          context,
          ...result.summary,
        });
        console.log(JSON.stringify({
          finished: label,
          cold_p50_ms: result.summary.cold.wall_ms.p50,
          warm_p50_ms: result.summary.warm_open.wall_ms.p50,
          warm_git_spawns: result.summary.warm_open.backend_git_spawns,
          live_p50_ms: result.summary.live.wall_ms.p50,
          live_cpu_p50_ms: result.summary.live.cpu_ms.p50,
        }));
      }
    }
    assert(
      await source_hash() === env.source_sha256,
      "Implementation changed during measurement",
    );
    json(join(options.output, "artifacts/summary.json"), summaries);
  } finally {
    closeMetrics();
  }
}
