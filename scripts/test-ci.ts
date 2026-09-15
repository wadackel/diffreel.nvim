import { CASES } from "../tests/stability.ts";
import {
  argumentsFor,
  assert,
  denoArgs,
  executable,
  join,
  json,
  lines,
  mkdir,
  now,
  resolve,
  ROOT,
  run,
} from "./lib.ts";
import { runSuite, type TestCommand, validateJobs } from "./test-runner.ts";

export function commandsFor(
  nvim: string,
  daemon: string,
  output: string,
): TestCommand[] {
  const commands: TestCommand[] = [...Deno.readDirSync(join(ROOT, "tests"))]
    .filter((entry) => entry.isFile && entry.name.endsWith(".lua")).map((
      entry,
    ) => entry.name).sort().map((
      name,
    ) => ({
      command: [
        nvim,
        "--headless",
        "-u",
        "NONE",
        "-i",
        "NONE",
        "--cmd",
        "let g:diffreel_daemon = $DIFFREEL_DAEMON",
        "-l",
        "tests/" + name,
      ],
    }));
  const unit = [...Deno.readDirSync(join(ROOT, "tests"))].filter((entry) =>
    entry.isFile && entry.name.endsWith("_test.ts")
  ).map((entry) => "tests/" + entry.name).sort();
  const append = (command: string[], exclusive = false) =>
    commands.push({ command, exclusive });
  append([Deno.execPath(), "test", "--frozen", "-A", ...unit], true);
  for (
    const name of ["daemon_shutdown", "pr_backend", "pr_ui", "pr_lifecycle"]
  ) append(denoArgs(`tests/${name}.ts`));
  for (const name of ["highlights_ui", "inline_ui", "explorer_resize", "e2e"]) {
    append(
      denoArgs(
        `tests/${name}.ts`,
        "--output",
        join(output, name.replaceAll("_", "-")),
      ),
    );
  }
  append(
    denoArgs(
      "tests/stability.ts",
      "--daemon",
      daemon,
      "--output",
      join(output, "stability"),
      "--cases",
      ...Object.keys(CASES).filter((name) => name !== "syntax-switch"),
    ),
    true,
  );
  append(
    denoArgs(
      "tests/exploratory.ts",
      "--daemon",
      daemon,
      "--output",
      join(output, "exploratory"),
    ),
  );
  append(
    denoArgs(
      "tests/stateful.ts",
      "--output",
      join(output, "stateful"),
      "--seeds",
      "3",
      "4",
      "17",
      "318",
      "--steps",
      "40",
    ),
    true,
  );
  return commands;
}

async function main() {
  const args = argumentsFor(
    { daemon: "", output: ".wadackel/qa/ci", jobs: 1 },
    ["daemon"],
  );
  const jobs = Number(args.jobs);
  validateJobs(jobs);
  const output = resolve(String(args.output)),
    daemon = resolve(String(args.daemon));
  mkdir(output);
  const nvim = executable("nvim");
  assert(nvim, "Neovim must be available on PATH");
  const denoDir = resolve(
    JSON.parse((await run([Deno.execPath(), "info", "--json"])).stdout).denoDir,
  );
  const environment = {
    platform: `${Deno.build.os}-${Deno.build.arch}`,
    nvim,
    nvim_version: lines((await run([nvim, "--version"])).stdout)[0],
    git_version: (await run(["git", "--version"])).stdout.trim(),
    deno_version: Deno.version,
    deno_dir: denoDir,
    daemon,
    daemon_build: JSON.parse((await run([daemon, "--build-info"])).stdout),
    jobs,
  };
  json(join(output, "environment.json"), environment);
  const started = now();
  try {
    const results = await runSuite(commandsFor(nvim, daemon, output), {
      jobs,
      cwd: ROOT,
      output,
      daemon,
      env: {
        ...Deno.env.toObject(),
        DIFFREEL_DAEMON: daemon,
        DENO_DIR: denoDir,
      },
    });
    Deno.exitCode = results.every((result) => result.passed) ? 0 : 1;
  } finally {
    json(join(output, "environment.json"), {
      ...environment,
      seconds: Number((now() - started).toFixed(3)),
    });
  }
}
if (import.meta.main) await main();
