import { assert, assertEquals, assertThrows } from "@std/assert";
import { manifestFor, TARGETS, validateManifest } from "../scripts/release.ts";
import {
  denoArgs,
  join,
  json,
  mkdir,
  read,
  ROOT,
  run,
  script,
  shellQuote,
  temporary,
  write,
} from "../scripts/lib.ts";

Deno.test("release manifests retain protocol, target, size and integrity validation", async () => {
  using temp = temporary("release-");
  const id = "a".repeat(64);
  for (const target of TARGETS) {
    write(join(temp.path, "diffreel-daemon-" + target), target);
  }
  const manifest = await manifestFor(temp.path, id),
    expected = JSON.parse(read(join(ROOT, "distribution.json"))).protocol;
  assertEquals(manifest.protocol, expected);
  validateManifest(manifest, id);
  for (const protocol of [expected - 1, expected + 1]) {
    assertThrows(() => validateManifest({ ...manifest, protocol }, id));
  }
  const target = TARGETS[0];
  assert(manifest.targets[target].sha256.length === 64);
  assertThrows(() => validateManifest({ ...manifest, targets: {} }, id));
  assertThrows(() =>
    validateManifest({
      ...manifest,
      targets: {
        ...manifest.targets,
        [target]: { ...manifest.targets[target], size: 0 },
      },
    }, id)
  );
});

interface Tampered {
  release: { isImmutable: boolean };
  signer?: string;
  commit?: string;
  digest?: string;
}

Deno.test("first publication, interrupted draft retry and immutable release reuse", async () => {
  using temp = temporary("release-lifecycle-");
  const bin = join(temp.path, "bin"), assets = join(temp.path, "assets");
  mkdir(bin);
  mkdir(assets);
  script(
    join(bin, "gh"),
    "#!/bin/sh\nexec " +
      denoArgs("tests/release_fixture.ts").map(shellQuote).join(" ") +
      ' "$@"\n',
  );
  const statePath = join(temp.path, "state.json"),
    output = join(temp.path, "output");
  json(statePath, { operations: [], interrupt: true });
  const env = {
    ...Deno.env.toObject(),
    PATH: bin,
    DIFFREEL_RELEASE_FIXTURE: temp.path,
    GITHUB_OUTPUT: output,
  };
  const id = "a".repeat(64);
  const invoke = (mode: string, ...args: string[]) =>
    run(denoArgs("scripts/release.ts", mode, id, assets, ...args), {
      env,
      check: false,
    });
  assert((await invoke("fetch", "--target", TARGETS[0])).success);
  assertEquals(read(output), "reused=false\n");
  for (const target of TARGETS) {
    write(join(assets, "diffreel-daemon-" + target), target);
  }
  assert(!(await invoke("publish", "--commit", "b".repeat(40))).success);
  let state = JSON.parse(read(statePath));
  assert(state.release.isDraft);
  assertEquals(state.release.assets.length, 1);
  assert(!state.operations.includes("edit"));
  assert((await invoke("publish", "--commit", "b".repeat(40))).success);
  state = JSON.parse(read(statePath));
  assertEquals(state.release.isDraft, false);
  assertEquals(state.release.isPrerelease, true);
  assertEquals(state.release.assets.length, TARGETS.length + 1);
  assertEquals(
    state.operations.filter((op: string) => op === "create").length,
    1,
  );
  const previous = state.operations.length;
  assert((await invoke("publish", "--commit", "b".repeat(40))).success);
  assert((await invoke("fetch", "--target", TARGETS[0])).success);
  state = JSON.parse(read(statePath));
  assert(
    state.operations.slice(previous).every((op: string) =>
      ["view", "download", "verify"].includes(op)
    ),
  );
  assertEquals(
    state.operations.slice(previous).filter((op: string) => op === "verify")
      .length,
    2,
  );
  assertEquals(read(output), "reused=false\nreused=true\n");
  for (const target of TARGETS) {
    assertEquals(read(join(assets, "diffreel-daemon-" + target)), target);
  }
  const published = read(statePath);
  const tampering: [string, (value: Tampered) => void][] = [
    ["Published release is not immutable", (value) => {
      value.release.isImmutable = false;
    }],
    ["does not cover this tag and commit", (value) => {
      value.commit = "c".repeat(40);
    }],
    ["not signed by the GitHub release signer", (value) => {
      value.signer = "https://attacker.example";
    }],
    ["does not cover the verified assets", (value) => {
      value.digest = "0".repeat(64);
    }],
  ];
  for (const [message, tamper] of tampering) {
    const broken = JSON.parse(published);
    tamper(broken);
    json(statePath, broken);
    const result = await invoke("fetch", "--target", TARGETS[0]);
    assert(!result.success && result.stderr.includes(message), message);
  }
  write(statePath, published);
  assert((await invoke("fetch", "--target", TARGETS[0])).success);
});
