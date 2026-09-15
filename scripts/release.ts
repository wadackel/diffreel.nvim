import {
  assert,
  bytes,
  join,
  json,
  read,
  ROOT,
  run,
  sha256,
  temporary,
} from "./lib.ts";

const REPOSITORY = "github.com/wadackel/diffreel.nvim";
export const TARGETS: string[] =
  JSON.parse(read(join(ROOT, "distribution.json"))).targets;
export interface Asset {
  name: string;
  size: number;
  sha256: string;
}
export interface Manifest {
  build_id: string;
  protocol: number;
  targets: Record<string, Asset>;
}
interface Release {
  isDraft: boolean;
  isPrerelease: boolean;
  assets: { name: string; size: number }[];
}

function gh(args: string[], check = true) {
  return run(["gh", ...args, "--repo", REPOSITORY], { check });
}
export async function manifestFor(
  directory: string,
  buildId: string,
): Promise<Manifest> {
  const targets: Record<string, Asset> = {};
  for (const target of TARGETS) {
    const name = "diffreel-daemon-" + target,
      binary = join(directory, name),
      stat = Deno.lstatSync(binary);
    assert(stat.isFile && !stat.isSymlink, binary);
    const data = bytes(binary);
    targets[target] = { name, size: data.length, sha256: await sha256(data) };
  }
  return { build_id: buildId, protocol: 4, targets };
}
export function validateManifest(manifest: Manifest, buildId: string) {
  assert(
    manifest.build_id === buildId && manifest.protocol === 4,
    "Incompatible release manifest",
  );
  assert(
    Object.keys(manifest.targets).sort().join() === [...TARGETS].sort().join(),
    "Incomplete target set",
  );
  for (const [target, asset] of Object.entries(manifest.targets)) {
    assert(asset.name === "diffreel-daemon-" + target);
    assert(
      Number.isSafeInteger(asset.size) && asset.size > 0 &&
        asset.size <= 128 * 1024 * 1024,
    );
    assert(/^[0-9a-f]{64}$/.test(asset.sha256));
  }
}
async function release(buildId: string): Promise<Release | undefined> {
  const result = await gh([
    "release",
    "view",
    "daemon-" + buildId,
    "--json",
    "isDraft,isPrerelease,assets",
  ], false);
  if (result.success) return JSON.parse(result.stdout);
  if (result.stderr.toLowerCase().includes("not found")) return undefined;
  throw new Error(
    "Cannot inspect release; check authentication and connectivity",
  );
}
async function download(buildId: string, asset: string, destination: string) {
  await gh([
    "release",
    "download",
    "daemon-" + buildId,
    "--pattern",
    asset,
    "--output",
    destination,
    "--clobber",
  ]);
}
async function verifyCohort(
  buildId: string,
  state: Release,
  directory: string,
  target?: string,
  draft = false,
) {
  assert(state.isDraft === draft && state.isPrerelease);
  assert(
    state.assets.map((a) => a.name).sort().join() ===
      ["manifest.json", ...TARGETS.map((t) => "diffreel-daemon-" + t)].sort()
        .join(),
  );
  await download(buildId, "manifest.json", join(directory, "manifest.json"));
  const manifest: Manifest = JSON.parse(read(join(directory, "manifest.json")));
  validateManifest(manifest, buildId);
  const sizes = new Map(state.assets.map((a) => [a.name, a.size]));
  for (const [name, asset] of Object.entries(manifest.targets)) {
    assert(sizes.get(asset.name) === asset.size);
    if (target !== undefined && name !== target) continue;
    const binary = join(directory, asset.name);
    await download(buildId, asset.name, binary);
    assert(
      bytes(binary).length === asset.size &&
        await sha256(bytes(binary)) === asset.sha256,
    );
    Deno.chmodSync(binary, 0o755);
  }
  return manifest;
}
async function publish(buildId: string, directory: string, commit: string) {
  const state = await release(buildId);
  if (state && !state.isDraft) {
    using temp = temporary();
    await verifyCohort(buildId, state, temp.path);
    console.log("Reusing complete immutable release " + buildId);
    return;
  }
  const manifest = await manifestFor(directory, buildId);
  validateManifest(manifest, buildId);
  json(join(directory, "manifest.json"), manifest);
  const tag = "daemon-" + buildId;
  if (!state) {
    const notes = join(directory, "release-notes.md");
    Deno.writeTextFileSync(
      notes,
      "Native diffreel daemons for build inputs `" + buildId + "`.\n",
    );
    await gh([
      "release",
      "create",
      tag,
      "--draft",
      "--prerelease",
      "--target",
      commit,
      "--title",
      "Daemon " + buildId.slice(0, 12),
      "--notes-file",
      notes,
    ]);
  }
  await gh([
    "release",
    "upload",
    tag,
    ...TARGETS.map((target) => join(directory, "diffreel-daemon-" + target)),
    join(directory, "manifest.json"),
    "--clobber",
  ]);
  {
    using temp = temporary();
    const checked = await verifyCohort(
      buildId,
      (await release(buildId))!,
      temp.path,
      undefined,
      true,
    );
    assert(JSON.stringify(checked) === JSON.stringify(manifest));
  }
  await gh([
    "release",
    "edit",
    tag,
    "--draft=false",
    "--prerelease",
    "--latest=false",
  ]);
  {
    using temp = temporary();
    await verifyCohort(buildId, (await release(buildId))!, temp.path);
  }
}
if (import.meta.main) {
  const [mode, buildId, directory, ...rest] = Deno.args;
  if (mode === "--help") {
    console.log(
      "release.ts <fetch|publish> <build-id> <directory> [--target <target>] [--commit <sha>]",
    );
    Deno.exit(0);
  }
  assert(
    ["fetch", "publish"].includes(mode) && /^[0-9a-f]{64}$/.test(buildId) &&
      directory,
    "Invalid release arguments",
  );
  const options: Record<string, string> = {};
  for (let i = 0; i < rest.length; i += 2) {
    assert(["--target", "--commit"].includes(rest[i]) && rest[i + 1]);
    options[rest[i]] = rest[i + 1];
  }
  const target = options["--target"];
  assert(!target || TARGETS.includes(target));
  Deno.mkdirSync(directory, { recursive: true });
  if (mode === "publish") {
    assert(/^[0-9a-f]{40}$/.test(options["--commit"] ?? ""));
    await publish(buildId, directory, options["--commit"]);
  } else {
    const state = await release(buildId),
      reused = Boolean(state && !state.isDraft);
    if (reused) await verifyCohort(buildId, state!, directory, target);
    const output = Deno.env.get("GITHUB_OUTPUT");
    if (output) {
      Deno.writeTextFileSync(output, "reused=" + reused + "\n", {
        append: true,
      });
    }
    console.log("reused=" + reused);
  }
}
