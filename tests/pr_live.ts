import { parseArgs } from "@std/cli/parse-args";
import { Daemon } from "./pr_support.ts";
import {
  assert,
  assertEquals,
  exists,
  filesBelow,
  git,
  join,
  json,
  mkdir,
  read,
  resolve,
  ROOT,
} from "../scripts/lib.ts";

if (import.meta.main) {
  const args = parseArgs(Deno.args, {
    string: ["case", "output"],
    collect: ["case"],
    boolean: ["help"],
  });
  if (args.help) {
    console.log(
      "pr_live.ts --case <merge|squash|rebase|closed-unmerged|indirect-rollup> [--case ...] --output <directory>",
    );
    Deno.exit(0);
  }
  assert(args.output && args.case?.length);
  const output = resolve(args.output);
  mkdir(output);
  const binary = resolve(Deno.env.get("DIFFREEL_DAEMON")!);
  const results = [];
  for (
    const path of filesBelow(join(ROOT, "tests/fixtures/pr")).filter((p) =>
      p.endsWith(".json")
    ).sort()
  ) {
    const expected = JSON.parse(read(path));
    if (!args.case.includes(expected.case)) continue;
    const root = join(output, expected.repository.replaceAll("/", "-"));
    if (!exists(root)) {
      mkdir(root);
      await git(root, "init", "-qb", "main");
      await git(
        root,
        "remote",
        "add",
        "origin",
        "https://github.com/" + expected.repository + ".git",
      );
    }
    const daemon = await Daemon.create(binary, root, Deno.env.toObject());
    try {
      const { job_id } = await daemon.call("pr/prepare", {
          view_id: "live",
          pr: expected.source_url,
        }),
        acquired = (await daemon.prepared(job_id, 130)).result;
      assert(
        acquired.base === expected.base_sha &&
          acquired.head === expected.head_sha,
      );
      assert(acquired.merge_base === expected.comparison.merge_base);
      const snapshot = await daemon.call("comparison/open", {
        view_id: "live",
        left: acquired.merge_base,
        right: acquired.head,
      });
      const actual = Object.fromEntries(
        snapshot.entries.map((
          entry: {
            path: string;
            left: { oid?: string };
            right: { oid?: string };
          },
        ) => [entry.path, entry]),
      );
      assertEquals(
        new Set(Object.keys(actual)),
        new Set(expected.pr_files.map((item: { path: string }) => item.path)),
      );
      for (const [side, key] of [["left", "merge_base"], ["right", "head"]]) {
        for (
          const [name, value] of Object.entries(
            expected.endpoint_blobs[key].blobs,
          )
        ) assertEquals(actual[name][side].oid, value);
      }
      const result = {
        fixture: path,
        url: expected.source_url,
        passed: true,
        files: Object.keys(actual).length,
        snapshot: acquired,
        daemon: binary,
      };
      results.push(result);
      console.log(JSON.stringify(result));
      await daemon.call("comparison/close", { view_id: "live" });
    } finally {
      await daemon.close();
      json(join(output, "results.json"), results);
    }
  }
  assert(results.length > 0, "No matching PR fixtures");
}
