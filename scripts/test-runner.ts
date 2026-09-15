import { assert, failure, join, json, mkdir, now, run, write } from "./lib.ts";

export interface TestCommand {
  command: string[];
  exclusive?: boolean;
}

export function validateJobs(jobs: number) {
  assert(
    Number.isSafeInteger(jobs) && jobs >= 1,
    "jobs must be a positive integer",
  );
}

export async function schedule(
  commands: { exclusive?: boolean }[],
  jobs: number,
  execute: (index: number) => Promise<void>,
) {
  validateJobs(jobs);
  let cursor = 0;
  while (cursor < commands.length) {
    if (commands[cursor].exclusive) {
      await execute(cursor++);
      continue;
    }
    let end = cursor;
    while (end < commands.length && !commands[end].exclusive) end++;
    let next = cursor;
    const workers = await Promise.allSettled(
      Array.from({ length: Math.min(jobs, end - cursor) }, async () => {
        while (next < end) await execute(next++);
      }),
    );
    const failed = workers.find((worker) => worker.status === "rejected");
    if (failed?.status === "rejected") throw failed.reason;
    cursor = end;
  }
}

interface TestResult {
  index: number;
  command: string[];
  backend: string;
  configuration: string;
  daemon: string;
  passed: boolean;
  seconds: number;
}

export async function runSuite(
  commands: TestCommand[],
  options: {
    jobs: number;
    cwd: string;
    output: string;
    daemon: string;
    env: Record<string, string>;
  },
) {
  validateJobs(options.jobs);
  const environments = join(options.output, "environments");
  mkdir(environments);
  const results: (TestResult | undefined)[] = Array(commands.length);
  const completed = () => results.filter((result) => result !== undefined);
  await schedule(commands, options.jobs, async (index) => {
    const { command } = commands[index];
    const label = String(index).padStart(2, "0");
    const directory = Deno.makeTempDirSync({
      dir: environments,
      prefix: label + "-",
    });
    const env = { ...options.env };
    for (
      const key of [
        "HOME",
        "XDG_CONFIG_HOME",
        "XDG_DATA_HOME",
        "XDG_STATE_HOME",
        "XDG_CACHE_HOME",
      ]
    ) {
      env[key] = join(directory, key.toLowerCase());
      mkdir(env[key]);
    }
    env.GIT_CONFIG_GLOBAL = "/dev/null";
    env.GIT_CONFIG_NOSYSTEM = "1";
    const started = now();
    let passed = false, log = "";
    try {
      const result = await run(command, {
        cwd: options.cwd,
        env,
        check: false,
        timeout: 600,
      });
      passed = result.success;
      log = result.stdout + result.stderr;
    } catch (error) {
      log = failure(error);
    }
    write(join(options.output, label + ".log"), log);
    const result = {
      index,
      command,
      backend: "rust",
      configuration: "minimal",
      daemon: options.daemon,
      passed,
      seconds: Number((now() - started).toFixed(3)),
    };
    results[index] = result;
    console.log(JSON.stringify(result));
    if (!passed) console.log(log);
    json(join(options.output, "results.json"), completed());
  });
  return completed();
}
