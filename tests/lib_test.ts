import { assertEquals, assertRejects, assertThrows } from "@std/assert";
import {
  argumentsFor,
  exists,
  join,
  mkdir,
  pathsBelow,
  read,
  run,
  temporary,
} from "../scripts/lib.ts";

Deno.test("command deadline survives a parent exiting before its pipe holder", async () => {
  const started = performance.now();
  await assertRejects(
    () => run(["/bin/sh", "-c", "sleep 3 >&2 &"], { timeout: 0.2 }),
    Error,
    "Timed out",
  );
  assertEquals(performance.now() - started < 1500, true);
});

Deno.test("cleanup checks retain empty installation staging directories", () => {
  using temp = temporary("staging-");
  const stage = join(temp.path, ".install-empty");
  mkdir(stage);
  assertEquals(pathsBelow(temp.path).includes(stage), true);
});

Deno.test("CLI options retain multi-value arguments and reject invalid numbers", () => {
  assertEquals(
    argumentsFor({ cases: ["default"], samples: 2 }, [], [
      "--cases",
      "one",
      "two",
      "--samples",
      "3",
    ]),
    { cases: ["one", "two"], samples: 3 },
  );
  assertThrows(() =>
    argumentsFor({ samples: 2 }, [], ["--samples", "invalid"])
  );
});

Deno.test("command deadlines remove owned descendants", async () => {
  using temp = temporary("command-timeout-");
  const marker = join(temp.path, "child.pid");
  const code =
    `const child=new Deno.Command(Deno.execPath(),{args:["eval","--no-config","setInterval(()=>{},1000)"],stdin:"null",stdout:"null",stderr:"null"}).spawn();Deno.writeTextFileSync(${
      JSON.stringify(marker)
    },String(child.pid));await new Promise(()=>{});`;
  try {
    await assertRejects(
      () =>
        run([Deno.execPath(), "eval", "--no-config", code], { timeout: 0.5 }),
      Error,
      "Timed out",
    );
    const status = await run(["ps", "-o", "stat=", "-p", read(marker)], {
      check: false,
    });
    assertEquals(!status.success || status.stdout.trim().startsWith("Z"), true);
  } finally {
    if (exists(marker)) {
      try {
        Deno.kill(Number(read(marker)), "SIGKILL");
      } catch { /* The deadline should already have reaped the child. */ }
    }
  }
});
