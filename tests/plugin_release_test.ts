import { assert, assertEquals, assertStringIncludes } from "@std/assert";
import {
  denoArgs,
  join,
  read,
  run,
  script,
  shellQuote,
  temporary,
  write,
} from "../scripts/lib.ts";

Deno.test("plugin publication requires the sole pending release's tested commit", async (t) => {
  using temp = temporary("plugin-release-");
  const sha = "a".repeat(40), other = "b".repeat(40);
  const pending = (commit = sha, number = 1) => ({
    number,
    merged_at: "2026-09-15T00:00:00Z",
    merge_commit_sha: commit,
    labels: [{ name: "autorelease: pending" }],
  });
  const cases = [
    { name: "no releases", pages: [[]], publish: false },
    { name: "matching commit", pages: [[pending()]], publish: true },
    {
      name: "later page",
      pages: [[{ ...pending(), merged_at: null }], [pending()]],
      publish: true,
    },
    { name: "another commit", pages: [[pending(other)]], publish: false },
    {
      name: "multiple pending releases across pages",
      pages: [[pending()], [pending(other, 2)]],
      error: "Multiple pending releases",
    },
    {
      name: "completed publication",
      pages: [[{ ...pending(), labels: [{ name: "autorelease: tagged" }] }]],
      publish: false,
    },
    {
      name: "published release awaiting label repair",
      pages: [[pending()]],
      publish: true,
    },
    { name: "API failure", pages: [[]], status: 1, error: "exited 1" },
    {
      name: "malformed response",
      pages: {},
      error: "Invalid pull request pages",
    },
    {
      name: "missing merge SHA",
      pages: [[{ ...pending(), merge_commit_sha: null }]],
      error: "Invalid merge commit",
    },
  ];
  for (const test of cases) {
    await t.step(test.name, async () => {
      const output = join(temp.path, "output"), args = join(temp.path, "args");
      write(output, "");
      script(
        join(temp.path, "gh"),
        "#!/bin/sh\n" +
          `printf '%s\\n' "$@" > ${shellQuote(args)}\n` +
          `printf '%s\\n' ${shellQuote(JSON.stringify(test.pages))}\n` +
          `exit ${test.status ?? 0}\n`,
      );
      const result = await run(denoArgs("scripts/plugin-release.ts"), {
        env: {
          PATH: temp.path,
          GITHUB_REPOSITORY: "wadackel/diffreel.nvim",
          GITHUB_SHA: sha,
          GITHUB_OUTPUT: output,
        },
        check: false,
      });
      if (test.error) {
        assert(!result.success);
        assertStringIncludes(result.stderr, test.error);
        assertEquals(read(output), "");
      } else {
        assert(result.success, result.stderr);
        assertEquals(read(output), `publish=${test.publish}\n`);
        if (test.name === "another commit") {
          assertStringIncludes(result.stdout, other);
          assertStringIncludes(result.stdout, "Re-run");
        }
      }
      assertEquals(read(args).trim().split("\n"), [
        "api",
        "--method",
        "GET",
        "--paginate",
        "--slurp",
        "repos/wadackel/diffreel.nvim/pulls?state=closed&base=main&per_page=100",
      ]);
    });
  }
});
