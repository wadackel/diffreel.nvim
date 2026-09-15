import { Nvim, PLUGIN } from "./support.ts";
import {
  argumentsFor,
  assert,
  bytes,
  copyTree,
  encoder,
  executable,
  filesBelow,
  git,
  join,
  mkdir,
  pathsBelow,
  read,
  remove,
  resolve,
  run,
  script,
  sha256,
  shellQuote,
  temporary,
  wait,
  write,
} from "../scripts/lib.ts";

async function main() {
  const args = argumentsFor({ daemon: "" }, ["daemon"]),
    daemon = resolve(String(args.daemon)),
    binary = bytes(daemon);
  const info = JSON.parse((await run([daemon, "--build-info"])).stdout);
  const expected = (await run([
    "nvim",
    "--headless",
    "-u",
    "NONE",
    "-i",
    "NONE",
    "-l",
    join(PLUGIN, "scripts/build-id.lua"),
  ])).stdout.trim();
  assert(
    info.build_id === expected,
    "Build the fixture daemon with DIFFREEL_BUILD_ID from scripts/build-id.lua",
  );
  const asset = "diffreel-daemon-" + info.target;
  const manifest = async (id: string, data: Uint8Array) =>
    encoder.encode(
      JSON.stringify({
        build_id: id,
        protocol: 4,
        targets: {
          [info.target]: {
            name: asset,
            size: data.length,
            sha256: await sha256(data),
          },
        },
      }),
    );
  const payloads: Record<string, Record<string, Uint8Array>> = {
    ["daemon-" + expected]: {
      [asset]: binary,
      "manifest.json": await manifest(expected, binary),
    },
  };
  const requests: string[] = [];
  let release!: () => void, gate: Promise<void>;
  const hold = () => {
    gate = new Promise<void>((resolve) => {
      release = resolve;
    });
  };
  hold();
  const server = Deno.serve(
    { hostname: "127.0.0.1", port: 0, onListen() {} },
    async (request) => {
      const path = new URL(request.url).pathname;
      requests.push(path);
      await gate;
      const [tag, name] = path.slice(1).split("/"),
        data = payloads[tag]?.[name];
      return data
        ? new Response(new Uint8Array(data), {
          headers: { "Content-Length": String(data.length) },
        })
        : new Response("Not found", { status: 404 });
    },
  );
  const editors = new Set<Nvim>();
  using temp = temporary("diffreel-install-");
  const root = temp.path;
  try {
    const worktree = join(root, "repo"), bin = join(root, "bin");
    mkdir(worktree);
    mkdir(bin);
    await git(worktree, "init", "-q");
    write(join(worktree, "file.txt"), "baseline\n");
    await git(worktree, "add", ".");
    await git(worktree, "commit", "-qm", "baseline");
    write(join(worktree, "file.txt"), "changed\n");
    for (const name of ["nvim", "git", "sh", "uname"]) {
      const path = executable(name);
      assert(path, "Missing runtime tool " + name);
      Deno.symlinkSync(path, join(bin, name));
    }
    const curl = executable("curl");
    assert(curl);
    script(
      join(bin, "curl"),
      `#!/bin/sh
set -eu
seen=0
for arg do
  case "$arg" in
    =https) value='=http' ;;
    https://github.com/wadackel/diffreel.nvim/releases/download/daemon-*)
      value='http://127.0.0.1:${server.addr.port}/'"\${arg#https://github.com/wadackel/diffreel.nvim/releases/download/}"
      seen=1 ;;
    *) value="$arg" ;;
  esac
  set -- "$@" "$value"
  shift
done
[ "$seen" = 1 ]
exec ${shellQuote(curl)} "$@"
`,
    );
    const env = {
      ...Deno.env.toObject(),
      PATH: bin,
      XDG_DATA_HOME: join(root, "data"),
    };
    const editor = async (auto = true) => {
      const nvim = await Nvim.create(worktree, { env, daemon: false });
      editors.add(nvim);
      await nvim.lua(
        "assert(vim.fn.executable('gh')+vim.fn.executable('deno')+vim.fn.executable('python3')+vim.fn.executable('cargo')+vim.fn.executable('rustc')+vim.fn.executable('nix')==0);require('diffreel').setup({auto_install=...,watch=false});_G.view=require('diffreel').open()",
        auto,
      );
      return nvim;
    };
    const first = await editor(), second = await editor();
    await wait(() => requests.length === 2);
    assert(await first.lua("return 6*7") === 42, "Fetching blocked the editor");
    await first.lua("require('diffreel').close(view)");
    release();
    await second.wait("return view.ready and not view.updating", 30);
    assert(
      await first.lua(
        "return next(require('diffreel').views)==nil and next(require('diffreel').managers)==nil",
      ),
    );
    for (const nvim of [first, second]) {
      await nvim.close();
      editors.delete(nvim);
    }
    let count = requests.length;
    const cached = await editor(false);
    await cached.wait("return view.ready and not view.updating");
    assert(requests.length === count, "Cache hit accessed the network");
    const cachePath = join(
      await cached.lua(
        "return require('diffreel.install').path(require('diffreel.distribution').current())",
      ),
      "diffreel-daemon",
    );
    await cached.lua("require('diffreel').close(view)");
    await cached.close();
    editors.delete(cached);
    // Linux refuses in-place writes while an exiting process still maps the executable.
    const replacement = cachePath + ".broken";
    write(replacement, "broken");
    Deno.chmodSync(replacement, Deno.statSync(cachePath).mode! & 0o777);
    Deno.renameSync(replacement, cachePath);
    const damaged = await editor(false);
    await damaged.wait("return view.error and not view.updating");
    assert(requests.length === count);
    await damaged.lua(
      "require('diffreel').setup({auto_install=true});require('diffreel').refresh(view)",
    );
    await damaged.wait("return view.ready and not view.updating", 30);
    await damaged.close();
    editors.delete(damaged);
    const updated = join(root, "updated-plugin");
    mkdir(updated);
    for (const name of ["lua", "daemon", "scripts"]) {
      copyTree(join(PLUGIN, name), join(updated, name), [
        "target",
        "__pycache__",
      ]);
    }
    for (
      const name of ["distribution.json", ".gitattributes", ".deno-version"]
    ) Deno.copyFileSync(join(PLUGIN, name), join(updated, name));
    const hookEnv = { ...env, XDG_DATA_HOME: join(root, "hook-data") };
    const hook = () =>
      run([
        join(bin, "nvim"),
        "--headless",
        "-u",
        "NONE",
        "-i",
        "NONE",
        "-l",
        join(updated, "scripts/install.lua"),
      ], { cwd: root, env: hookEnv, timeout: 30 });
    await hook();
    const settings = read(join(updated, "distribution.json"));
    write(join(updated, "distribution.json"), settings + "\n");
    const nextId = (await run([
      "nvim",
      "--headless",
      "-u",
      "NONE",
      "-i",
      "NONE",
      "-l",
      join(updated, "scripts/build-id.lua"),
    ])).stdout.trim();
    assert(nextId !== expected);
    const nextBinary = encoder.encode(
      "#!/bin/sh\nprintf '%s\\n' " +
        shellQuote(JSON.stringify({ ...info, build_id: nextId })) + "\n",
    );
    payloads["daemon-" + nextId] = {
      [asset]: nextBinary,
      "manifest.json": await manifest(nextId, nextBinary),
    };
    await hook();
    const receipts = filesBelow(join(root, "hook-data")).filter((path) =>
      path.endsWith("/installed.json")
    ).map((path) => JSON.parse(read(path)).build_id);
    assert(
      [...new Set(receipts)].sort().join() === [expected, nextId].sort().join(),
    );
    write(join(updated, "distribution.json"), settings);
    count = requests.length;
    await hook();
    assert(
      requests.length === count,
      "Rollback did not reuse the previous cache",
    );
    remove(join(env.XDG_DATA_HOME, "nvim/diffreel"));
    hold();
    count = requests.length;
    const exiting = await editor();
    await wait(() => requests.length > count);
    await exiting.close();
    editors.delete(exiting);
    release();
    await wait(() =>
      !pathsBelow(env.XDG_DATA_HOME).some((path) =>
        path.split("/").some((part) => part.startsWith(".install-"))
      )
    );
    console.log(JSON.stringify({
      passed: true,
      build_id: expected,
      cases: [
        "concurrent editors",
        "responsive fetch",
        "close during fetch",
        "verified offline cache",
        "corruption and retry",
        "fresh install/update hooks",
        "rollback cache",
        "exit during fetch",
        "no development runtimes",
      ],
    }));
  } finally {
    release();
    for (const nvim of editors) await nvim.close();
    await server.shutdown();
  }
}
if (import.meta.main) await main();
