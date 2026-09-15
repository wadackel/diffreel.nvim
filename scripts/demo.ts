import {
  assert,
  bytes,
  copyTree,
  executable,
  exists,
  filesBelow,
  invocation,
  join,
  json,
  mkdir,
  read,
  resolve,
  ROOT,
  run,
  sha256,
  shellQuote,
  write,
} from "./lib.ts";

const source = join(ROOT, "docs/assets/vhs");
const scenes = [
  "review",
  "layout-stacked",
  "layout-inline",
  "review-edit",
  "live-update",
];
const dependencies = {
  "vim-dogrun": [
    "wadackel/vim-dogrun",
    "354919a7e4660fa293c2feb7f561637eafcf1820",
  ],
  "nvim-web-devicons": [
    "nvim-tree/nvim-web-devicons",
    "5f032a85be210cd1c6ac98861eb3b187ff3bd5eb",
  ],
};
const filename = (scene: string) =>
  `${scene}.${
    scene.endsWith("edit") || scene === "live-update" ? "gif" : "png"
  }`;

export async function createFixture(
  directory: string,
  inherited = Deno.env.toObject(),
) {
  const repo = join(directory, "diffreel-demo");
  const env: Record<string, string> = {};
  for (const key of ["PATH", "TERM", "COLORTERM", "LANG", "LC_ALL", "TMPDIR"]) {
    if (inherited[key]) env[key] = inherited[key];
  }
  Object.assign(env, {
    HOME: join(directory, "home"),
    GIT_CONFIG_NOSYSTEM: "1",
    GIT_CONFIG_GLOBAL: "/dev/null",
    GIT_CONFIG_COUNT: "0",
    GIT_AUTHOR_DATE: "2026-01-01T00:00:00+00:00",
    GIT_COMMITTER_DATE: "2026-01-01T00:00:00+00:00",
    NVIM_APPNAME: "nvim",
  });
  mkdir(env.HOME);
  for (const kind of ["CONFIG", "DATA", "STATE", "CACHE"]) {
    env[`XDG_${kind}_HOME`] = join(directory, kind.toLowerCase());
  }
  mkdir(join(repo, "src"));
  const git = async (...args: string[]) =>
    (await run([
      "git",
      "-c",
      "user.name=Example",
      "-c",
      "user.email=example@example.invalid",
      "-c",
      "commit.gpgsign=false",
      "-c",
      "core.hooksPath=/dev/null",
      "-c",
      "core.autocrlf=false",
      ...args,
    ], { cwd: repo, env })).stdout.trim();
  await git("init", "-q", "-b", "main", "--object-format=sha1", "--template=");
  write(
    join(repo, "src/review.lua"),
    read(join(source, "fixtures/before.lua")),
  );
  write(join(repo, "src/config.lua"), "return { width = 28 }\n");
  write(
    join(repo, "README.md"),
    "# Review helpers\n\nFormat and filter changing files.\n",
  );
  await git("add", ".");
  await git("commit", "-qm", "Add review helpers");
  const baseline = await git("rev-parse", "HEAD");
  write(join(repo, "src/review.lua"), read(join(source, "fixtures/after.lua")));
  write(
    join(repo, "src/config.lua"),
    "return { width = 35, show_deleted = true }\n",
  );
  write(
    join(repo, "README.md"),
    "# Review helpers\n\nFilter file paths without case sensitivity.\n",
  );
  return { repo, baseline, env };
}

export async function publish(
  directory: string,
  output: string,
  scene: string,
) {
  const verified = JSON.parse(read(join(directory, "verified.json")));
  assert(
    verified.passed === true && verified.scene === scene,
    "Scene verification did not finish",
  );
  const name = filename(scene);
  assert(Deno.statSync(join(directory, name)).size > 0, "Empty recording");
  await Deno.copyFile(join(directory, name), join(output, name));
}

async function fontFile() {
  const override = Deno.env.get("DIFFREEL_DEMO_FONT");
  if (override) return resolve(override);
  if (Deno.build.os === "darwin") {
    for (
      const directory of [
        join(Deno.env.get("HOME")!, "Library/Fonts"),
        "/Library/Fonts",
      ]
    ) {
      const found = filesBelow(directory).find((path) =>
        path.endsWith("/JetBrainsMonoNerdFontMono-Regular.ttf")
      );
      if (found) return found;
    }
  } else if (executable("fc-match")) {
    const match = (await run([
      "fc-match",
      "-f",
      "%{family}|%{file}",
      "JetBrainsMono Nerd Font Mono",
    ])).stdout;
    const [family, file] = match.split("|");
    if (family.split(",").includes("JetBrainsMono Nerd Font Mono")) return file;
  }
  throw new Error(
    "Install JetBrainsMono Nerd Font Mono; set DIFFREEL_DEMO_FONT to its installed regular TTF if it cannot be located.",
  );
}

async function main() {
  const selected = Deno.args.length === 1 && Deno.args[0] === "all"
    ? scenes
    : Deno.args;
  assert(
    selected.length > 0 && selected.every((scene) => scenes.includes(scene)),
    `Usage: just demo <${scenes.join("|")}> or just demo-all`,
  );
  const daemon = resolve(
    Deno.env.get("DIFFREEL_DAEMON") ??
      join(ROOT, "daemon/target/debug/diffreel-daemon"),
  );
  assert(
    exists(daemon),
    "Build the daemon with just build, or set DIFFREEL_DAEMON",
  );
  const versions: Record<string, unknown> = {};
  for (
    const [tool, flag] of [
      ["vhs", "--version"],
      ["ffmpeg", "-version"],
      ["ttyd", "--version"],
      ["nvim", "--version"],
      ["git", "--version"],
    ]
  ) {
    const path = executable(tool);
    assert(path, `Missing recording dependency: ${tool}`);
    versions[tool] = {
      path,
      version: (await run([path, flag])).stdout.trim().split("\n")[0],
    };
  }
  const font = await fontFile();
  const sources = [
    ...filesBelow(join(ROOT, "lua")),
    ...filesBelow(join(ROOT, "plugin")),
    ...filesBelow(source),
    join(ROOT, "scripts/demo.ts"),
  ].sort();
  const sourceHashes = await Promise.all(
    sources.map(async (
      path,
    ) => [path.slice(ROOT.length + 1), await sha256(bytes(path))]),
  );
  const identity = {
    command: invocation(),
    backend: "rust",
    configuration: "isolated VHS",
    source: ROOT,
    source_sha256: await sha256(JSON.stringify(sourceHashes)),
    source_commit: (await run(["git", "rev-parse", "HEAD"], { cwd: ROOT }))
      .stdout.trim(),
    source_status:
      (await run(["git", "status", "--short"], { cwd: ROOT })).stdout,
    platform: `${Deno.build.os}-${Deno.build.arch}`,
    deno: Deno.version,
    versions,
    font,
    font_sha256: await sha256(bytes(font)),
    daemon,
    daemon_sha256: await sha256(bytes(daemon)),
    build_info: JSON.parse((await run([daemon, "--build-info"])).stdout),
    dependencies,
    limits:
      "VHS terminal rendering; tool and installed font versions can change pixels. Scene checks do not replace the UI test suites.",
  };
  const cache = join(ROOT, ".wadackel/qa/vhs");
  mkdir(cache);
  const paths: Record<string, string> = {};
  for (const [name, [repo, commit]] of Object.entries(dependencies)) {
    const path = join(cache, `${name}-${commit}`);
    if (!exists(path)) {
      await run([
        "git",
        "clone",
        "--no-checkout",
        `https://github.com/${repo}.git`,
        path,
      ]);
      await run([
        "git",
        "-c",
        "core.hooksPath=/dev/null",
        "checkout",
        "--detach",
        commit,
      ], { cwd: path });
    }
    assert(
      (await run(["git", "rev-parse", "HEAD"], { cwd: path })).stdout.trim() ===
        commit,
      `Wrong dependency revision: ${path}`,
    );
    assert(
      (await run(["git", "status", "--porcelain"], { cwd: path })).stdout ===
        "",
      `Modified dependency: ${path}`,
    );
    paths[name] = path;
  }
  for (const scene of selected) {
    const directory = Deno.makeTempDirSync({ dir: cache, prefix: `${scene}-` });
    console.log(`Recording ${scene}: ${directory}`);
    copyTree(source, join(directory, "tapes"));
    const fixture = await createFixture(directory);
    const editorEnv = {
      ...fixture.env,
      DIFFREEL_DEMO_RUN: directory,
      DIFFREEL_DEMO_ROOT: ROOT,
      DIFFREEL_DEMO_SCENE: scene,
      DIFFREEL_DAEMON: daemon,
      DIFFREEL_DEMO_THEME: paths["vim-dogrun"],
      DIFFREEL_DEMO_ICONS: paths["nvim-web-devicons"],
    };
    json(join(directory, "environment.json"), editorEnv);
    write(
      join(directory, "nvim.sh"),
      "exec env -i " + Object.entries(editorEnv).map(([key, value]) =>
        shellQuote(`${key}=${value}`)
      ).join(" ") + " nvim -n -i NONE -u tapes/init.lua\n",
    );
    const evidence = { ...identity, scene, baseline_commit: fixture.baseline };
    json(join(directory, "capture.json"), { ...evidence, passed: false });
    try {
      await run(["vhs", "validate", `tapes/${scene}.tape`], { cwd: directory });
      const result = await run(["vhs", `tapes/${scene}.tape`], {
        cwd: directory,
        env: { ...Deno.env.toObject(), VHS_PUBLISH: "false" },
        timeout: 180,
        check: false,
      });
      write(join(directory, "vhs.log"), result.stdout + result.stderr);
      assert(result.success, `VHS failed; see ${join(directory, "vhs.log")}`);
      await publish(directory, join(ROOT, "docs/assets"), scene);
      json(join(directory, "capture.json"), {
        ...evidence,
        passed: true,
        output_sha256: await sha256(bytes(join(directory, filename(scene)))),
      });
    } catch (error) {
      json(join(directory, "capture.json"), {
        ...evidence,
        passed: false,
        error: String(error),
      });
      throw error;
    }
  }
}

if (import.meta.main) await main();
