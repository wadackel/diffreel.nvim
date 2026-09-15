import { assertEquals } from "@std/assert";
import { create } from "../benchmarks/fixtures.ts";
import { join, run, temporary } from "../scripts/lib.ts";

Deno.test("S/M fixtures retain tracked files, changed files and historical baseline", async () => {
  using temp = temporary("diffreel-fixtures-");
  for (const [name, count] of [["S", 19], ["M", 102]] as const) {
    const manifest = await create(join(temp.path, name), name),
      cwd = manifest.root;
    assertEquals(
      (await run(["git", "ls-files", "-z"], { cwd })).stdout.split("\0")
        .length - 1,
      612,
    );
    assertEquals(
      (await run(["git", "diff", "--name-only", "-z", manifest.left], { cwd }))
        .stdout.split("\0").length - 1,
      count,
    );
    if (name === "M") {
      assertEquals(
        (await run(["git", "rev-parse", "HEAD~20"], { cwd })).stdout.trim(),
        manifest.left,
      );
    }
  }
});
