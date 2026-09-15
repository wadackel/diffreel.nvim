import { assert, denoArgs, lines, run } from "../scripts/lib.ts";

const fields = [
  "user",
  "system",
  "package_wakeups",
  "interrupt_wakeups",
  "pageins",
  "wired",
  "resident",
  "footprint",
  "start",
  "exit",
  "child_user",
  "child_system",
  "child_package_wakeups",
  "child_interrupt_wakeups",
  "child_pageins",
  "child_elapsed",
  "disk_read",
  "disk_write",
] as const;
type Usage = Record<typeof fields[number], bigint>;
function openLibraries() {
  assert(Deno.build.os === "darwin", "Process accounting requires macOS");
  return {
    proc: Deno.dlopen("/usr/lib/libproc.dylib", {
      proc_pid_rusage: { parameters: ["i32", "i32", "buffer"], result: "i32" },
    }),
    system: Deno.dlopen("/usr/lib/libSystem.B.dylib", {
      mach_timebase_info: { parameters: ["buffer"], result: "i32" },
      getrusage: { parameters: ["i32", "buffer"], result: "i32" },
    }),
  };
}
let libraries: ReturnType<typeof openLibraries> | undefined;
function native() {
  return libraries ??= openLibraries();
}
export function close() {
  libraries?.proc.close();
  libraries?.system.close();
  libraries = undefined;
}
export function usage(pid: number): Usage {
  const buffer = new Uint8Array(160);
  if (native().proc.symbols.proc_pid_rusage(pid, 2, buffer) !== 0) {
    throw new Deno.errors.NotFound("Cannot sample PID " + pid);
  }
  const view = new DataView(buffer.buffer);
  return Object.fromEntries(
    fields.map((
      name,
      index,
    ) => [name, view.getBigUint64(16 + index * 8, true)]),
  ) as Usage;
}
export function cpuSeconds(who = 0) {
  const buffer = new Uint8Array(144);
  assert(
    native().system.symbols.getrusage(who, buffer) === 0,
    "getrusage failed",
  );
  const view = new DataView(buffer.buffer);
  return Number(view.getBigInt64(0, true) + view.getBigInt64(16, true)) +
    Number(view.getBigInt64(8, true) + view.getBigInt64(24, true)) / 1e6;
}
export function burn(seconds: number) {
  const end = cpuSeconds() + seconds;
  while (cpuSeconds() < end) { /* Sleeping does not exercise the CPU clock. */ }
}
function scale(raw: bigint, measuredNs: number, mach: number) {
  const factor =
    [...new Set([1, mach])].sort((a, b) =>
      Math.abs(Number(raw) * a - measuredNs) -
      Math.abs(Number(raw) * b - measuredNs)
    )[0];
  const error = Math.abs(Number(raw) * factor - measuredNs) / measuredNs;
  assert(
    error <= 0.05,
    `CPU clock calibration failed: ${raw} ${measuredNs} ${factor} ${error}`,
  );
  return [factor, error];
}
export interface Clock {
  source: string;
  own_ns_per_unit: number;
  child_ns_per_unit: number;
  own_calibration_error: number;
  child_calibration_error: number;
  mach_ns_per_tick: number;
}
export async function calibrate(): Promise<Clock> {
  const buffer = new Uint8Array(8);
  assert(native().system.symbols.mach_timebase_info(buffer) === 0);
  const view = new DataView(buffer.buffer),
    mach = view.getUint32(0, true) / view.getUint32(4, true);
  let before = usage(Deno.pid), expected = cpuSeconds();
  burn(0.08);
  let after = usage(Deno.pid), observed = cpuSeconds();
  const [own, ownError] = scale(
    after.user + after.system - before.user - before.system,
    (observed - expected) * 1e9,
    mach,
  );
  before = usage(Deno.pid);
  expected = cpuSeconds(-1);
  await run(denoArgs("benchmarks/metrics.ts", "--burn", "0.08"));
  after = usage(Deno.pid);
  observed = cpuSeconds(-1);
  const [child, childError] = scale(
    after.child_user + after.child_system - before.child_user -
      before.child_system,
    (observed - expected) * 1e9,
    mach,
  );
  return {
    source: "proc_pid_rusage RUSAGE_INFO_V2",
    own_ns_per_unit: own,
    child_ns_per_unit: child,
    own_calibration_error: ownError,
    child_calibration_error: childError,
    mach_ns_per_tick: mach,
  };
}
export async function processFamily(parent: number) {
  const tree = new Map<number, number[]>();
  for (const line of lines((await run(["ps", "-axo", "pid=,ppid="])).stdout)) {
    const [pid, ppid] = line.trim().split(/\s+/).map(Number);
    tree.set(ppid, [...(tree.get(ppid) ?? []), pid]);
  }
  const found = new Set([parent]), pending = [parent];
  while (pending.length) {
    for (const pid of tree.get(pending.pop()!) ?? []) {
      if (!found.has(pid)) {
        found.add(pid);
        pending.push(pid);
      }
    }
  }
  return found;
}
export interface Sample {
  cpu_ms: number;
  rss_bytes: number;
  footprint_bytes: number;
  processes: {
    pid: number;
    start: string;
    own_cpu_ms: number;
    waited_child_cpu_ms: number;
    rss_bytes: number;
    footprint_bytes: number;
  }[];
}
export async function sample(parent: number, clock: Clock): Promise<Sample> {
  const processes: Sample["processes"] = [];
  for (const pid of [...await processFamily(parent)].sort((a, b) => a - b)) {
    let value;
    try {
      value = usage(pid);
    } catch (error) {
      if (pid !== parent && error instanceof Deno.errors.NotFound) continue;
      throw error;
    }
    processes.push({
      pid,
      start: String(value.start),
      own_cpu_ms: Number(value.user + value.system) * clock.own_ns_per_unit /
        1e6,
      waited_child_cpu_ms: Number(value.child_user + value.child_system) *
        clock.child_ns_per_unit / 1e6,
      rss_bytes: Number(value.resident),
      footprint_bytes: Number(value.footprint),
    });
  }
  return {
    cpu_ms: processes.reduce(
      (sum, p) => sum + p.own_cpu_ms + p.waited_child_cpu_ms,
      0,
    ),
    rss_bytes: processes.reduce((sum, p) => sum + p.rss_bytes, 0),
    footprint_bytes: processes.reduce((sum, p) => sum + p.footprint_bytes, 0),
    processes,
  };
}
if (import.meta.main) {
  assert(Deno.args[0] === "--burn" && Number(Deno.args[1]) > 0);
  try {
    burn(Number(Deno.args[1]));
  } finally {
    close();
  }
}
