import {
  assert,
  dirname,
  exists,
  join,
  json,
  lines,
  mkdir,
  read,
  resolve,
  run,
  sha256,
  write,
} from "../scripts/lib.ts";

export const CASES: Record<string, [number, number]> = {
  S: [612, 19],
  M: [612, 102],
  L: [7043, 37],
  XL: [60000, 40],
};
export interface Fixture {
  case: string;
  root: string;
  tracked_files: number;
  changed_files: number;
  left: string;
  head: string;
  paths: string[];
  versions: number[];
  fsmonitor: boolean;
  source_lines: number;
  filler_content: string;
}
export function content(index: number, version: number) {
  const rows = [
    `export const value = ${version};`,
    `export const fileId = ${index};`,
    "export function transform(input: number): number {",
    "  let total = input;",
  ];
  for (let number = 0; number < 112; number++) {
    rows.push(
      `  total += ${(number + index) % 7 + (number === 55 ? version : 0)};`,
    );
  }
  return [...rows, "  return total;", "}"].join("\n") + "\n";
}
async function command(root: string, args: string[], sequence = 0) {
  const env = {
    ...Deno.env.toObject(),
    GIT_AUTHOR_DATE: `@${1000000000 + sequence} +0000`,
    GIT_COMMITTER_DATE: `@${1000000000 + sequence} +0000`,
  };
  return (await run([
    "git",
    "-c",
    "user.name=Example",
    "-c",
    "user.email=example@example.invalid",
    "-c",
    "commit.gpgsign=false",
    "-c",
    "core.hooksPath=/dev/null",
    ...args,
  ], { cwd: root, env })).stdout.trim();
}
export async function create(
  directory: string,
  name: string,
): Promise<Fixture> {
  const root = resolve(directory),
    manifestPath = root.replace(/\.[^/.]+$/, "") + ".json";
  if (exists(manifestPath)) {
    const manifest = JSON.parse(read(manifestPath));
    assert(
      await command(root, ["rev-parse", "HEAD"]) === manifest.head,
      "Fixture HEAD changed: " + root,
    );
    return manifest;
  }
  assert(!exists(root), "Refusing to reuse incomplete fixture: " + root);
  assert(name in CASES, "Unknown fixture case: " + name);
  const [total, changed] = CASES[name];
  mkdir(join(root, "src"));
  write(
    join(root, "package.json"),
    '{"name":"diffreel-benchmark-fixture","private":true}\n',
  );
  write(
    join(root, "tsconfig.json"),
    '{"compilerOptions":{"strict":true,"noEmit":true,"target":"ES2022"},"include":["src"]}\n',
  );
  const paths = [];
  for (let index = 0; index < changed; index++) {
    const path = `src/change_${String(index).padStart(3, "0")}.ts`;
    paths.push(path);
    write(join(root, path), content(index, 0));
  }
  for (let index = 0; index < total - changed - 2; index++) {
    const path = join(
      root,
      `data/${String(Math.floor(index / 1000)).padStart(3, "0")}/${
        String(index).padStart(6, "0")
      }.txt`,
    );
    mkdir(dirname(path));
    write(path, "fixture\n");
  }
  await command(root, ["init", "-q"]);
  for (
    const [key, value] of [
      ["core.fsmonitor", "false"],
      ["core.excludesFile", "/dev/null"],
      ["core.attributesFile", "/dev/null"],
      ["core.autocrlf", "false"],
    ]
  ) await command(root, ["config", key, value]);
  await command(root, ["add", "."]);
  await command(root, ["commit", "-qm", "baseline"]);
  const baseline = await command(root, ["rev-parse", "HEAD"]),
    versions = Array(changed).fill(1);
  if (name === "M") {
    for (let batch = 0; batch < 20; batch++) {
      for (let index = batch; index < changed; index += 20) {
        versions[index] = batch + 1;
        write(join(root, paths[index]), content(index, versions[index]));
      }
      await command(root, ["add", "src"]);
      await command(root, ["commit", "-qm", `batch ${batch + 1}`], batch + 1);
    }
  } else {for (const [index, path] of paths.entries()) {
      write(join(root, path), content(index, 1));
    }}
  const manifest: Fixture = {
    case: name,
    root,
    tracked_files: total,
    changed_files: changed,
    left: baseline,
    head: await command(root, ["rev-parse", "HEAD"]),
    paths,
    versions,
    fsmonitor: false,
    source_lines: lines(content(0, 0)).length,
    filler_content:
      "identical plain text; excluded from the TypeScript project",
  };
  json(manifestPath, manifest);
  return manifest;
}
export function restore(manifest: Fixture) {
  for (const [index, path] of manifest.paths.entries()) {
    write(join(manifest.root, path), content(index, manifest.versions[index]));
  }
}
export async function expected(
  manifest: Fixture,
  versions = manifest.versions,
) {
  return Object.fromEntries(
    await Promise.all(
      manifest.paths.map(async (
        path,
        index,
      ) => [path, await sha256(content(index, versions[index]))]),
    ),
  );
}
