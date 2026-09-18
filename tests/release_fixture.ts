import {
  assert,
  basename,
  bytes,
  join,
  json,
  read,
  sha256,
} from "../scripts/lib.ts";

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
    isImmutable: boolean;
    targetCommitish: string;
    assets: { name: string; size: number }[];
  };
  operations: string[];
  interrupt: boolean;
  signer?: string;
  commit?: string;
  digest?: string;
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
  state.release = {
    isDraft: true,
    isPrerelease: true,
    isImmutable: false,
    targetCommitish: option("--target"),
    assets: [],
  };
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
  state.release.isImmutable = true;
  save();
} else if (operation === "verify") {
  assert(state.release && !state.release.isDraft);
  assert(option("--format") === "json");
  save();
  const release = state.release;
  console.log(JSON.stringify({
    verificationResult: {
      signature: {
        certificate: {
          subjectAlternativeName: state.signer ??
            "https://dotcom.releases.github.com",
        },
      },
      statement: {
        subject: [
          {
            uri: "pkg:github/wadackel/diffreel.nvim@" + tag,
            digest: { sha1: state.commit ?? release.targetCommitish },
          },
          ...await Promise.all(release.assets.map(async (asset) => ({
            name: asset.name,
            digest: {
              sha256: asset.name === "manifest.json" && state.digest
                ? state.digest
                : await sha256(bytes(join(root, asset.name))),
            },
          }))),
        ],
      },
    },
  }));
} else {
  throw new Error("Unexpected release operation: " + operation);
}
