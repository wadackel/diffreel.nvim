import { assertEquals, assertRejects, assertThrows } from "@std/assert";
import {
  argumentsFor,
  join,
  mkdir,
  pathsBelow,
  read,
  run,
  shellQuote,
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
  // An interpreter start can outlast the deadline on a slow machine, leaving no pid to check.
  const code = `sleep 30 >/dev/null 2>&1 & printf %s "$!" > ${
    shellQuote(marker + ".tmp")
  } && mv ${shellQuote(marker + ".tmp")} ${shellQuote(marker)}; wait`;
  let pid = 0;
  try {
    await assertRejects(
      () => run(["/bin/sh", "-c", code], { timeout: 0.5 }),
      Error,
      "Timed out",
    );
    // A ps invocation rejecting its argument would satisfy the check below without reading a process.
    pid = Number(read(marker).trim());
    assertEquals(pid > 0, true);
    const status = await run(["ps", "-o", "stat=", "-p", String(pid)], {
      check: false,
    });
    assertEquals(!status.success || status.stdout.trim().startsWith("Z"), true);
  } finally {
    if (pid > 0) {
      try {
        Deno.kill(pid, "SIGKILL");
      } catch { /* The deadline should already have reaped the child. */ }
    }
  }
});
