import { type ChildProcessWithoutNullStreams, spawn } from "node:child_process";
import { Readable, Writable } from "node:stream";
import { constants } from "node:os";

export class Process {
  readonly pid: number;
  readonly stdin: WritableStream<Uint8Array>;
  readonly stdout: ReadableStream<Uint8Array>;
  readonly stderr: ReadableStream<Uint8Array>;
  readonly status: Promise<
    { code: number; success: boolean; signal: string | null }
  >;
  private constructor(private child: ChildProcessWithoutNullStreams) {
    this.pid = child.pid!;
    this.stdin = Writable.toWeb(child.stdin) as WritableStream<Uint8Array>;
    this.stdout = Readable.toWeb(child.stdout) as ReadableStream<Uint8Array>;
    this.stderr = Readable.toWeb(child.stderr) as ReadableStream<Uint8Array>;
    this.status = new Promise((resolve) =>
      child.once("exit", (code, signal) =>
        resolve({
          code: code ?? 128 + (signal ? constants.signals[signal] : 1),
          success: code === 0 && signal === null,
          signal,
        }))
    );
  }
  static async spawn(
    command: string,
    options: { args?: string[]; cwd?: string; env?: Record<string, string> } =
      {},
  ) {
    const child = spawn(command, options.args ?? [], {
      cwd: options.cwd,
      env: options.env,
      detached: true,
      stdio: "pipe",
    });
    await new Promise<void>((resolve, reject) => {
      child.once("spawn", resolve);
      child.once("error", reject);
    });
    return new Process(child);
  }
  kill(signal: Deno.Signal = "SIGTERM") {
    Deno.kill(this.pid, signal);
  }
  terminate() {
    // An exited parent can leave pipe holders reparented outside a process-tree scan.
    try {
      Deno.kill(-this.pid, "SIGKILL");
    } catch (error) {
      if (!(error instanceof Deno.errors.NotFound)) throw error;
    }
  }
  destroyPipes() {
    this.child.stdin.destroy();
    this.child.stdout.destroy();
    this.child.stderr.destroy();
  }
  async output() {
    const [status, stdout, stderr] = await Promise.all([
      this.status,
      new Response(this.stdout).arrayBuffer(),
      new Response(this.stderr).arrayBuffer(),
    ]);
    return {
      ...status,
      stdout: new Uint8Array(stdout),
      stderr: new Uint8Array(stderr),
    };
  }
}

export async function within<T>(
  value: Promise<T>,
  seconds: number,
  message: string,
) {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      value,
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error(message)), seconds * 1000);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}
