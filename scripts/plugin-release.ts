import { assert, run } from "./lib.ts";

async function main() {
  const repository = Deno.env.get("GITHUB_REPOSITORY"),
    sha = Deno.env.get("GITHUB_SHA"),
    output = Deno.env.get("GITHUB_OUTPUT");
  assert(repository && /^[\w.-]+\/[\w.-]+$/.test(repository));
  assert(sha && /^[0-9a-f]{40}$/.test(sha));
  const result = await run([
    "gh",
    "api",
    "--method",
    "GET",
    "--paginate",
    "--slurp",
    `repos/${repository}/pulls?state=closed&base=main&per_page=100`,
  ]);
  const pages: unknown = JSON.parse(result.stdout);
  assert(
    Array.isArray(pages) && pages.length > 0 && pages.every(Array.isArray),
    "Invalid pull request pages",
  );
  const pending: { number: number; sha: string }[] = [];
  for (const pr of pages.flat()) {
    assert(
      pr && Array.isArray(pr.labels) && "merged_at" in pr,
      "Invalid pull request",
    );
    const labels = pr.labels.map((label: { name: string }) => {
      assert(label && typeof label.name === "string", "Invalid label");
      return label.name;
    });
    if (pr.merged_at === null || !labels.includes("autorelease: pending")) {
      continue;
    }
    assert(
      typeof pr.merge_commit_sha === "string" &&
        /^[0-9a-f]{40}$/.test(pr.merge_commit_sha),
      "Invalid merge commit",
    );
    assert(Number.isSafeInteger(pr.number) && pr.number > 0);
    pending.push({ number: pr.number, sha: pr.merge_commit_sha });
  }
  assert(
    pending.length <= 1,
    "Multiple pending releases; resolve before publishing",
  );
  const candidate = pending[0], publish = candidate?.sha === sha;
  if (!candidate) {
    console.log("No pending plugin release");
  } else if (!publish) {
    console.log(
      `Skipping release PR #${candidate.number}: tested ${sha}, pending ${candidate.sha}. Re-run CI for the pending merge commit.`,
    );
  } else {
    console.log(`Release PR #${candidate.number} matches tested commit ${sha}`);
  }
  if (output) {
    Deno.writeTextFileSync(output, `publish=${publish}\n`, { append: true });
  }
}

if (import.meta.main) await main();
