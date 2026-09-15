import { assertEquals, assertRejects } from "@std/assert";
import { createFixture, publish } from "../scripts/demo.ts";
import { join, mkdir, read, run, temporary, write } from "../scripts/lib.ts";

Deno.test("demo fixtures reproduce Git identity without using global config", async () => {
  using temp = temporary("demo-test-");
  const config = join(temp.path, "gitconfig");
  write(config, "[commit]\n\tgpgsign = true\n[core]\n\tautocrlf = true\n");
  const env = { ...Deno.env.toObject(), GIT_CONFIG_GLOBAL: config };
  const first = await createFixture(join(temp.path, "first"), env);
  const second = await createFixture(join(temp.path, "second"), env);
  assertEquals(first.baseline, second.baseline);
  assertEquals(
    read(config),
    "[commit]\n\tgpgsign = true\n[core]\n\tautocrlf = true\n",
  );
  const status = await run(["git", "status", "--porcelain"], {
    cwd: first.repo,
    env: first.env,
  });
  assertEquals(
    status.stdout,
    " M README.md\n M src/config.lua\n M src/review.lua\n",
  );
  assertEquals(
    read(join(first.repo, "src/review.lua")),
    read(join(second.repo, "src/review.lua")),
  );
  assertEquals(first.env.HOME, join(temp.path, "first/home"));
});

Deno.test("failed or unfinished recordings preserve the published image", async () => {
  using temp = temporary("demo-publish-");
  const output = join(temp.path, "output");
  mkdir(output);
  write(join(output, "review.png"), "existing image");
  write(join(temp.path, "review.png"), "replacement image");
  await assertRejects(() => publish(temp.path, output, "review"));
  assertEquals(read(join(output, "review.png")), "existing image");
  write(
    join(temp.path, "verified.json"),
    JSON.stringify({ scene: "review", passed: false }),
  );
  await assertRejects(() => publish(temp.path, output, "review"));
  assertEquals(read(join(output, "review.png")), "existing image");
  write(
    join(temp.path, "verified.json"),
    JSON.stringify({ scene: "review", passed: true }),
  );
  await publish(temp.path, output, "review");
  assertEquals(read(join(output, "review.png")), "replacement image");
});
