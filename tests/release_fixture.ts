import { assert, basename, join, json, read } from "../scripts/lib.ts";

const [command, operation, tag, ...args] = Deno.args;
assert(command === "release" && tag === "daemon-" + "a".repeat(64));
const option = (name: string) => args[args.indexOf(name) + 1];
assert(option("--repo") === "github.com/wadackel/diffreel.nvim");
const root = Deno.env.get("DIFFREEL_RELEASE_FIXTURE")!;
const statePath = join(root, "state.json");
const state: {
  release?: {
    isDraft: boolean;
    isPrerelease: boolean;
    assets: { name: string; size: number }[];
  };
  operations: string[];
  interrupt: boolean;
} = JSON.parse(read(statePath));
state.operations.push(operation);
const save = () => json(statePath, state);
if (operation === "view") {
  save();
  if (!state.release) {
    console.error("release not found");
    Deno.exit(1);
  }
  console.log(JSON.stringify(state.release));
} else if (operation === "create") {
  assert(
    !state.release && args.includes("--draft") && args.includes("--prerelease"),
  );
  assert(option("--target") === "b".repeat(40));
  state.release = { isDraft: true, isPrerelease: true, assets: [] };
  save();
} else if (operation === "upload") {
  assert(state.release?.isDraft);
  for (const path of args.slice(0, args.indexOf("--clobber"))) {
    const name = basename(path);
    Deno.copyFileSync(path, join(root, name));
    state.release.assets = state.release.assets.filter((asset) =>
      asset.name !== name
    );
    state.release.assets.push({ name, size: Deno.statSync(path).size });
    if (state.interrupt) {
      state.interrupt = false;
      save();
      console.error("interrupted upload");
      Deno.exit(1);
    }
  }
  save();
} else if (operation === "download") {
  Deno.copyFileSync(join(root, option("--pattern")), option("--output"));
  save();
} else if (operation === "edit") {
  assert(state.release?.isDraft && state.release.assets.length === 5);
  assert(args.includes("--draft=false") && args.includes("--prerelease"));
  state.release.isDraft = false;
  save();
} else {
  throw new Error("Unexpected release operation: " + operation);
}
