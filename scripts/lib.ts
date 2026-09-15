import { Process } from "./process.ts";
import { assert } from "@std/assert";
export { assert, assertEquals } from "@std/assert";
export { equal } from "@std/assert/equal";
export {
  basename,
  dirname,
  extname,
  fromFileUrl,
  join,
  relative,
  resolve,
  toFileUrl,
} from "@std/path";
import { dirname, fromFileUrl, join, resolve } from "@std/path";

export const ROOT = dirname(dirname(fromFileUrl(import.meta.url)));
export const encoder = new TextEncoder();
export const decoder = new TextDecoder();
export const now = () => performance.now() / 1000;
export const sleep = (seconds: number) =>
  new Promise<void>((resolve) => setTimeout(resolve, seconds * 1000));
export const read = (path: string) => Deno.readTextFileSync(path);
export const bytes = (path: string) => Deno.readFileSync(path);
export const mkdir = (path: string) =>
  Deno.mkdirSync(path, { recursive: true });
export function write(path: string, value: string | Uint8Array) {
  if (typeof value === "string") Deno.writeTextFileSync(path, value);
  else Deno.writeFileSync(path, value);
}
export function json(path: string, value: unknown) {
  write(path, JSON.stringify(value, null, 2) + "\n");
}
export function exists(path: string) {
  try {
    Deno.lstatSync(path);
    return true;
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) return false;
    throw error;
  }
}
export function remove(path: string) {
  try {
    Deno.removeSync(path, { recursive: true });
  } catch (error) {
    if (!(error instanceof Deno.errors.NotFound)) throw error;
  }
}
export function copyTree(
  source: string,
  target: string,
  exclude: string[] = [],
) {
  mkdir(target);
  for (const entry of Deno.readDirSync(source)) {
    if (exclude.includes(entry.name)) continue;
    const from = join(source, entry.name), to = join(target, entry.name);
    if (entry.isDirectory) copyTree(from, to, exclude);
    else if (entry.isSymlink) Deno.symlinkSync(Deno.readLinkSync(from), to);
    else {
      Deno.copyFileSync(from, to);
      Deno.chmodSync(to, Deno.statSync(from).mode!);
    }
  }
}
export function filesBelow(directory: string): string[] {
  return pathsBelow(directory).filter((path) =>
    !Deno.lstatSync(path).isDirectory
  );
}
export function pathsBelow(directory: string): string[] {
  if (!exists(directory)) return [];
  return [...Deno.readDirSync(directory)].flatMap((entry) => {
    const path = join(directory, entry.name);
    return entry.isDirectory ? [path, ...pathsBelow(path)] : [path];
  });
}
export function temporary(
  prefix = "diffreel-",
  dir = join(ROOT, ".wadackel/qa/deno"),
) {
  mkdir(dir);
  const path = Deno.realPathSync(Deno.makeTempDirSync({ dir, prefix }));
  return {
    path,
    [Symbol.dispose]() {
      remove(path);
    },
  };
}
export async function sha256(data: string | Uint8Array) {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    typeof data === "string" ? encoder.encode(data) : new Uint8Array(data),
  );
  return Array.from(
    new Uint8Array(digest),
    (n) => n.toString(16).padStart(2, "0"),
  ).join("");
}
export function executable(name: string, env = Deno.env.toObject()) {
  for (const directory of (env.PATH ?? "").split(":")) {
    const path = resolve(directory, name);
    try {
      const stat = Deno.statSync(path);
      if (stat.isFile && ((stat.mode ?? 0) & 0o111)) return path;
    } catch (error) {
      if (!(error instanceof Deno.errors.NotFound)) throw error;
    }
  }
  return undefined;
}
export function shellQuote(value: string) {
  return "'" + value.replaceAll("'", "'\\''") + "'";
}
export function script(path: string, source: string) {
  write(path, source);
  Deno.chmodSync(path, 0o755);
}
export function denoArgs(file: string, ...args: string[]) {
  return [
    Deno.execPath(),
    "run",
    "--frozen",
    "-A",
    "--config",
    join(ROOT, "deno.json"),
    join(ROOT, file),
    ...args,
  ];
}
export function invocation() {
  return [
    Deno.execPath(),
    "run",
    "--frozen",
    "-A",
    "--config",
    join(ROOT, "deno.json"),
    fromFileUrl(Deno.mainModule),
    ...Deno.args,
  ];
}
export interface RunOptions {
  cwd?: string;
  env?: Record<string, string>;
  check?: boolean;
  timeout?: number;
  input?: string | Uint8Array;
}
export function terminate(pid: number, signal: Deno.Signal = "SIGKILL") {
  try {
    Deno.kill(pid, signal);
  } catch (error) {
    if (!(error instanceof Deno.errors.NotFound)) throw error;
  }
}
export async function run(args: string[], options: RunOptions = {}) {
  const child = await Process.spawn(args[0], {
    args: args.slice(1),
    cwd: options.cwd,
    env: options.env,
  });
  let timedOut = false, completed = false;
  let drainTimer: ReturnType<typeof setTimeout> | undefined;
  const output = child.output();
  const timer = setTimeout(() => {
    timedOut = true;
    child.terminate();
    drainTimer = setTimeout(() => child.destroyPipes(), 1000);
  }, (options.timeout ?? 60) * 1000);
  try {
    if (options.input === undefined) await child.stdin.close();
    if (options.input !== undefined) {
      const writer = child.stdin.getWriter();
      try {
        await writer.write(
          typeof options.input === "string"
            ? encoder.encode(options.input)
            : options.input,
        );
      } finally {
        await writer.close();
      }
    }
    const result = await output;
    completed = true;
    const value = {
      ...result,
      raw: result.stdout,
      stdout: decoder.decode(result.stdout),
      stderr: decoder.decode(result.stderr),
    };
    assert(!timedOut, `Timed out: ${args.join(" ")}`);
    if (options.check !== false) {
      assert(
        result.success,
        `${
          args.join(" ")
        } exited ${result.code}\n${value.stdout}\n${value.stderr}`,
      );
    }
    return value;
  } finally {
    clearTimeout(timer);
    clearTimeout(drainTimer);
    if (!completed) {
      child.terminate();
      child.destroyPipes();
      await output.catch(() => {});
    }
  }
}
export async function git(root: string, ...args: string[]) {
  return (await run([
    "git",
    "-c",
    "user.name=Example",
    "-c",
    "user.email=example@example.invalid",
    "-c",
    "commit.gpgsign=false",
    "-c",
    "core.hooksPath=/dev/null",
    ...args,
  ], { cwd: root })).stdout.trim();
}
export async function wait(
  check: () => unknown | Promise<unknown>,
  timeout = 10,
  message = "Condition timed out",
) {
  const deadline = now() + timeout;
  while (!(await check())) {
    assert(now() < deadline, message);
    await sleep(0.01);
  }
}
export function lines(text: string) {
  return text
    ? text.replace(/\r\n/g, "\n").replace(/[\r\n]$/, "").split(/\r\n|\n|\r/)
    : [];
}
export function range(start: number, end?: number) {
  if (end === undefined) [start, end] = [0, start];
  return Array.from({ length: Math.max(0, end - start) }, (_, i) => start + i);
}
export function first<T>(values: T[]): T {
  assert(values.length > 0, "No matching item");
  return values[0];
}
export function includes(value: unknown, item: unknown) {
  if (typeof value === "string") return value.includes(String(item));
  if (Array.isArray(value)) return value.includes(item);
  return value !== null && typeof value === "object" &&
    Object.hasOwn(value, String(item));
}
export function failure(error: unknown) {
  return error instanceof Error ? error.stack ?? error.message : String(error);
}

export function argumentsFor(
  defaults: Record<string, string | number | boolean | string[] | number[]>,
  required: string[] = [],
  argv = Deno.args,
) {
  const result = { ...defaults };
  for (let i = 0; i < argv.length; i++) {
    const [flag, inline] = argv[i].split(/=(.*)/s, 2);
    if (flag === "--help" || flag === "-h") {
      console.log(
        Object.entries(defaults).map(([key, value]) =>
          `--${key}${typeof value === "boolean" ? "" : " <value>"}${
            required.includes(key)
              ? " (required)"
              : ` (default: ${JSON.stringify(value)})`
          }`
        ).join("\n"),
      );
      Deno.exit(0);
    }
    assert(
      flag.startsWith("--") && flag.slice(2) in defaults,
      `Unknown argument: ${flag}`,
    );
    const key = flag.slice(2), initial = defaults[key];
    if (typeof initial === "boolean") {
      assert(inline === undefined, `Unexpected value for ${flag}`);
      result[key] = true;
      continue;
    }
    const values = inline === undefined ? [] : [inline];
    while (
      i + 1 < argv.length && !argv[i + 1].startsWith("--") &&
      (Array.isArray(initial) || values.length === 0)
    ) values.push(argv[++i]);
    assert(values.length, `Missing value for ${flag}`);
    result[key] = Array.isArray(initial)
      ? (typeof initial[0] === "number" ? values.map(Number) : values)
      : typeof initial === "number"
      ? Number(values[0])
      : values[0];
    if (
      typeof initial === "number" ||
      (Array.isArray(initial) && typeof initial[0] === "number")
    ) {
      const numbers = Array.isArray(result[key])
        ? result[key] as number[]
        : [result[key] as number];
      assert(
        numbers.every((value) =>
          Number.isFinite(value) &&
          (["idle-seconds", "interval-ms", "live-interval-ms"].includes(key) ||
            Number.isSafeInteger(value))
        ),
        `Invalid number for ${flag}`,
      );
    }
  }
  for (const key of required) {
    assert(
      result[key] !== "" && result[key] !== undefined,
      `--${key} is required`,
    );
  }
  return result;
}
