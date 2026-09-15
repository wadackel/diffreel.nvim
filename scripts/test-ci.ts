import { CASES } from "../tests/stability.ts";
import {
  argumentsFor,
  assert,
  denoArgs,
  executable,
  failure,
  join,
  json,
  lines,
  mkdir,
  now,
  resolve,
  ROOT,
  run,
  write,
} from "./lib.ts";

async function main() {
  const args = argumentsFor({ daemon: "", output: ".wadackel/qa/ci" }, [
      "daemon",
    ]),
    output = resolve(String(args.output)),
    daemon = resolve(String(args.daemon));
  mkdir(output);
  const env = { ...Deno.env.toObject(), DIFFREEL_DAEMON: daemon },
    nvim = executable("nvim");
  assert(nvim, "Neovim must be available on PATH");
  json(join(output, "environment.json"), {
    platform: `${Deno.build.os}-${Deno.build.arch}`,
    nvim,
    nvim_version: lines((await run([nvim, "--version"])).stdout)[0],
    git_version: (await run(["git", "--version"])).stdout.trim(),
    deno_version: Deno.version,
    daemon,
    daemon_build: JSON.parse((await run([daemon, "--build-info"])).stdout),
  });
  const commands = [...Deno.readDirSync(join(ROOT, "tests"))].filter((entry) =>
    entry.isFile && entry.name.endsWith(".lua")
  ).map((entry) => entry.name).sort().map((
    name,
  ) => [
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
  ]);
  const unit = [...Deno.readDirSync(join(ROOT, "tests"))].filter((entry) =>
    entry.isFile && entry.name.endsWith("_test.ts")
  ).map((entry) => "tests/" + entry.name).sort();
  commands.push([Deno.execPath(), "test", "--frozen", "-A", ...unit]);
  for (
    const name of ["daemon_shutdown", "pr_backend", "pr_ui", "pr_lifecycle"]
  ) commands.push(denoArgs(`tests/${name}.ts`));
  for (const name of ["highlights_ui", "inline_ui", "e2e"]) {
    commands.push(
      denoArgs(
        `tests/${name}.ts`,
        "--output",
        join(output, name.replaceAll("_", "-")),
      ),
    );
  }
  commands.push(
    denoArgs(
      "tests/stability.ts",
      "--daemon",
      daemon,
      "--output",
      join(output, "stability"),
      "--cases",
      ...Object.keys(CASES).filter((name) => name !== "syntax-switch"),
    ),
  );
  commands.push(
    denoArgs(
      "tests/exploratory.ts",
      "--daemon",
      daemon,
      "--output",
      join(output, "exploratory"),
    ),
  );
  commands.push(
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
  );
  const results = [];
  for (const [index, command] of commands.entries()) {
    const started = now();
    let passed = false, log = "";
    try {
      const result = await run(command, {
        cwd: ROOT,
        env,
        check: false,
        timeout: 600,
      });
      passed = result.success;
      log = result.stdout + result.stderr;
    } catch (error) {
      log = failure(error);
    }
    write(join(output, String(index).padStart(2, "0") + ".log"), log);
    const result = {
      command,
      backend: "rust",
      configuration: "minimal",
      daemon,
      passed,
      seconds: Number((now() - started).toFixed(3)),
    };
    results.push(result);
    console.log(JSON.stringify(result));
    if (!passed) console.log(log);
    json(join(output, "results.json"), results);
  }
  Deno.exitCode = results.every((result) => result.passed) ? 0 : 1;
}
if (import.meta.main) await main();
