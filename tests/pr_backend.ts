import { git } from "./support.ts";
import {
  assert,
  bytes,
  equal,
  includes,
  join,
  mkdir,
  now,
  remove,
  resolve,
  temporary as makeTemp,
  toFileUrl,
  write,
} from "../scripts/lib.ts";

import { Daemon, fixture, unchanged_state } from "./pr_support.ts";
export async function scenario() {
  let accepted,
    acquired,
    before,
    daemon,
    env,
    failure,
    folder,
    fork,
    fork_before,
    history,
    job,
    limited,
    metadata,
    normal,
    result,
    root,
    shallow,
    snapshot,
    source,
    started;
  const binary = resolve(Deno.env.get("DIFFREEL_DAEMON")!);
  const output = ".wadackel/qa/2026-09-14-pr-fetch/backend";
  mkdir(output);
  {
    using temp_temporary = makeTemp("diffreel-", output);
    const temporary = temp_temporary.path;
    folder = resolve(temporary);
    [root, metadata, env] = await fixture(folder);
    await git(
      join(folder, "source"),
      "bundle",
      "create",
      String(join(folder, "all.bundle")),
      "--all",
    );
    write(
      join(folder, "bundle-list"),
      ('[bundle]\nversion = 1\nmode = all\nheuristic = creationToken\n[bundle "all"]\nuri = ' +
        String(join(folder, "all.bundle"))) + "\ncreationToken = 100\n",
    );
    await git(
      root,
      "config",
      "fetch.bundleURI",
      String(join(folder, "bundle-list")),
    );
    before = await unchanged_state(root);
    daemon = await Daemon.create(binary, root, env);
    try {
      normal = await daemon.call("comparison/open", {
        ["view_id"]: "ordinary",
      });
      write(join(folder, "slow"), "");
      started = now();
      accepted = await daemon.call("pr/prepare", {
        ["view_id"]: "pr",
        ["pr"]: 1,
      });
      assert(((now() - started) < 2) && accepted["job_id"]);
      await daemon.call("comparison/list", {
        ["comparison_id"]: normal["comparison_id"],
      }, 2);
      await daemon.call("pr/cache-clear", {}, 10, true);
      remove(join(folder, "slow"));
      result = (await daemon.prepared(accepted["job_id"]))["result"];
      assert(
        (equal(result["base"], metadata["base"]["sha"])) &&
          (equal(result["head"], metadata["head"]["sha"])),
      );
      assert(
        (equal(result["merge_base"], metadata["base"]["sha"])) &&
          (equal(result["number"], 1)),
      );
      snapshot = await daemon.call("comparison/open", {
        ["view_id"]: "pr",
        ["left"]: result["merge_base"],
        ["right"]: result["head"],
      });
      assert(
        equal(
          snapshot["entries"].map((entry: { path: string }) => entry["path"]),
          ["file.txt", "new.txt"],
        ),
      );
      assert(equal(await unchanged_state(root), before));
      await git(
        root,
        "remote",
        "set-url",
        "origin",
        "https://github.com/contributor/project.git",
      );
      fork_before = await unchanged_state(root);
      for (
        const [state, draft, merged] of [["draft", true, false], [
          "closed",
          false,
          false,
        ], ["merged", false, true]] as const
      ) {
        Object.assign(metadata, {
          state: (!equal(state, "draft")) ? "closed" : "open",
          draft: draft,
          merged: merged,
        });
        write(join(folder, "metadata.json"), JSON.stringify(metadata));
        acquired = await daemon.call("pr/prepare", {
          ["view_id"]: "fork",
          ["pr"]: "https://github.com/example/project/pull/1",
        });
        fork = (await daemon.prepared(acquired["job_id"]))["result"];
        assert(
          (equal(fork["state"], state)) &&
            (equal(fork["head"], metadata["head"]["sha"])),
        );
        await daemon.call("pr/release", { ["view_id"]: "fork" });
      }
      assert(equal(await unchanged_state(root), fork_before));
      source = join(folder, "source");
      await git(source, "switch", "main");
      write(join(source, "main-only.txt"), "advanced base\n");
      await git(source, "add", ".");
      await git(source, "commit", "-qm", "advance main");
      metadata["base"]["sha"] = await git(source, "rev-parse", "HEAD");
      await git(
        source,
        "push",
        "-q",
        String(join(folder, "remote.git")),
        "main",
      );
      shallow = join(folder, "shallow");
      await git(
        folder,
        "clone",
        "-q",
        "--depth=1",
        toFileUrl(join(folder, "remote.git")).href,
        String(shallow),
      );
      await git(
        shallow,
        "remote",
        "set-url",
        "origin",
        "https://github.com/example/project.git",
      );
      write(join(folder, "metadata.json"), JSON.stringify(metadata));
      history = bytes(join(shallow, ".git/shallow"));
      limited = await Daemon.create(binary, shallow, env);
      try {
        job = (await limited.call("pr/prepare", {
          ["view_id"]: "shallow",
          ["pr"]: 1,
        }))["job_id"];
        failure = await limited.prepared(job, 10, true);
        assert(includes(failure["error"], "shallow"));
        assert(equal(bytes(join(shallow, ".git/shallow")), history));
      } finally {
        await limited.close();
      }
      assert(
        includes(
          await git(root, "for-each-ref", "--format=%(refname)"),
          "refs/diffreel/pr/cache/",
        ),
      );
      await daemon.call("comparison/close", { ["view_id"]: "pr" });
      assert(
        includes(
          await git(root, "for-each-ref", "--format=%(refname)"),
          "refs/diffreel/pr/cache/",
        ),
      );
      await daemon.call("pr/cache-clear");
      assert(
        !(await git(
          root,
          "for-each-ref",
          "--format=%(refname)",
          "refs/diffreel/pr",
        )),
      );
      assert(equal(await unchanged_state(root), fork_before));
    } finally {
      await daemon.close();
    }
  }
  console.log(JSON.stringify({ ["passed"]: true }));
}
if (import.meta.main) await scenario();
