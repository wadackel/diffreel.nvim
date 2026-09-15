import { assert, assertEquals, assertRejects } from "@std/assert";
import {
  join,
  mkdir,
  read,
  ROOT,
  run,
  script,
  temporary,
} from "../scripts/lib.ts";
import { runSuite, schedule } from "../scripts/test-runner.ts";

const tick = () => new Promise<void>((resolve) => setTimeout(resolve, 0));

Deno.test("scheduler bounds parallel work and runs each command once", async () => {
  const gates = Array.from({ length: 5 }, () => Promise.withResolvers<void>());
  const started: number[] = [];
  const pending = schedule(gates.map(() => ({})), 2, async (index) => {
    started.push(index);
    await gates[index].promise;
  });
  try {
    assertEquals(started, [0, 1]);
    gates[1].resolve();
    await tick();
    assertEquals(started, [0, 1, 2]);
    gates[2].resolve();
    await tick();
    assertEquals(started, [0, 1, 2, 3]);
  } finally {
    for (const gate of gates) gate.resolve();
    await pending;
  }
  assertEquals(started, [0, 1, 2, 3, 4]);
});

Deno.test("exclusive commands drain the pool and block later commands", async () => {
  const gates = Array.from({ length: 4 }, () => Promise.withResolvers<void>());
  const started: number[] = [];
  const pending = schedule(
    [{}, {}, { exclusive: true }, {}],
    2,
    async (index) => {
      started.push(index);
      await gates[index].promise;
    },
  );
  try {
    assertEquals(started, [0, 1]);
    gates[0].resolve();
    await tick();
    assertEquals(started, [0, 1]);
    gates[1].resolve();
    await tick();
    assertEquals(started, [0, 1, 2]);
    gates[2].resolve();
    await tick();
    assertEquals(started, [0, 1, 2, 3]);
  } finally {
    for (const gate of gates) gate.resolve();
    await pending;
  }
});

Deno.test("serial scheduling preserves order and rejects invalid job counts", async () => {
  const events: string[] = [];
  await schedule([{}, { exclusive: true }, {}], 1, async (index) => {
    events.push("start " + index);
    await tick();
    events.push("end " + index);
  });
  assertEquals(events, [
    "start 0",
    "end 0",
    "start 1",
    "end 1",
    "start 2",
    "end 2",
  ]);
  for (const jobs of [0, -1, 1.5, NaN, Infinity]) {
    await assertRejects(
      () => schedule([], jobs, async () => {}),
      Error,
      "jobs",
    );
  }
});

Deno.test("suite retains ordered results, failures, isolated homes, and a shared Deno cache", async () => {
  using temp = temporary("test-runner-");
  const output = join(temp.path, "results"), cache = join(temp.path, "deno");
  const inspect = `
    const home = Deno.env.get("HOME");
    const previous = home + "/marker";
    if ((await Deno.stat(previous).catch(() => null))) throw new Error("shared home");
    Deno.writeTextFileSync(previous, "owned");
    console.log(JSON.stringify(Object.fromEntries(
      ["HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "DENO_DIR"]
        .map(key => [key, Deno.env.get(key)])
    )));
  `;
  const commands = [
    {
      command: [
        Deno.execPath(),
        "eval",
        "--no-config",
        `
      while (!(await Deno.stat(${
          JSON.stringify(join(output, "01.log"))
        }).catch(() => null))) {
        await new Promise(resolve => setTimeout(resolve, 5));
      }
      ${inspect}
    `,
      ],
    },
    { command: [join(temp.path, "missing-command")] },
    { command: [Deno.execPath(), "eval", "--no-config", inspect] },
    {
      command: ["/bin/sh", "-c", "printf 'expected failure'; exit 7"],
      exclusive: true,
    },
  ];
  const results = await runSuite(commands, {
    jobs: 2,
    cwd: temp.path,
    output,
    daemon: "/unused-daemon",
    env: { ...Deno.env.toObject(), DENO_DIR: cache },
  });
  assertEquals(results.map((result) => result.index), [0, 1, 2, 3]);
  assertEquals(results.map((result) => result.passed), [
    true,
    false,
    true,
    false,
  ]);
  assertEquals(
    results.map((result) => result.command),
    commands.map((item) => item.command),
  );
  assertEquals(JSON.parse(read(join(output, "results.json"))), results);
  assert(read(join(output, "01.log")).includes("missing-command"));
  assertEquals(read(join(output, "03.log")), "expected failure");
  const first = JSON.parse(read(join(output, "00.log")));
  const second = JSON.parse(read(join(output, "02.log")));
  for (
    const key of [
      "HOME",
      "XDG_CONFIG_HOME",
      "XDG_DATA_HOME",
      "XDG_STATE_HOME",
      "XDG_CACHE_HOME",
    ]
  ) {
    assert(first[key].startsWith(output));
    assert(second[key].startsWith(output));
    assert(first[key] !== second[key]);
  }
  assertEquals(first.DENO_DIR, cache);
  assertEquals(second.DENO_DIR, cache);
});

Deno.test("CI CLI rejects invalid jobs before inspecting the daemon", async () => {
  for (const value of ["0", "-1", "1.5", "invalid"]) {
    const result = await run([
      Deno.execPath(),
      "run",
      "--frozen",
      "-A",
      "scripts/test-ci.ts",
      "--daemon",
      "/missing-daemon",
      "--jobs",
      value,
    ], { check: false });
    assertEquals(result.success, false);
    assert(result.stderr.includes("jobs"));
    assert(!result.stderr.includes("Unknown argument"));
    assert(!result.stderr.includes("ENOENT"));
  }
});

Deno.test("CI CLI finishes later commands and exits nonzero after a test failure", async () => {
  using temp = temporary("test-ci-failure-");
  for (const directory of ["scripts", "tests", "bin"]) {
    mkdir(join(temp.path, directory));
  }
  for (
    const path of [
      "deno.json",
      "deno.lock",
      "scripts/lib.ts",
      "scripts/process.ts",
      "scripts/test-runner.ts",
      "scripts/test-ci.ts",
    ]
  ) {
    Deno.copyFileSync(join(ROOT, path), join(temp.path, path));
  }
  Deno.writeTextFileSync(
    join(temp.path, "tests/stability.ts"),
    "export const CASES = {};\n",
  );
  Deno.writeTextFileSync(
    join(temp.path, "tests/first.lua"),
    "error('expected failure')\n",
  );
  Deno.writeTextFileSync(
    join(temp.path, "tests/first_test.ts"),
    "Deno.test('unit', () => {});\n",
  );
  script(
    join(temp.path, "bin/nvim"),
    "#!/bin/sh\nif [ \"$1\" = --version ]; then echo 'NVIM fixture'; else exit 1; fi\n",
  );
  const daemon = join(temp.path, "bin/daemon");
  script(daemon, "#!/bin/sh\nprintf '%s\\n' '{\"build_id\":\"local\"}'\n");
  const output = join(temp.path, "output");
  const result = await run([
    Deno.execPath(),
    "run",
    "--frozen",
    "-A",
    "scripts/test-ci.ts",
    "--daemon",
    daemon,
    "--output",
    output,
    "--jobs",
    "2",
  ], {
    cwd: temp.path,
    env: {
      ...Deno.env.toObject(),
      PATH: join(temp.path, "bin") + ":" + Deno.env.get("PATH"),
    },
    check: false,
  });
  assertEquals(result.code, 1);
  const results = JSON.parse(read(join(output, "results.json")));
  assertEquals(results[0].passed, false);
  assertEquals(results[1].passed, true);
  assert(results.at(-1).command.includes(join(temp.path, "tests/stateful.ts")));
  const environment = JSON.parse(read(join(output, "environment.json")));
  assertEquals(environment.jobs, 2);
  assert(environment.seconds > 0);
});
