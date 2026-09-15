import { Process, within } from "../scripts/process.ts";
import {
  assert,
  bytes,
  executable,
  git,
  join,
  json,
  mkdir,
  now,
  ROOT,
  script,
  shellQuote,
  sleep,
  write,
} from "../scripts/lib.ts";
import { frame, Message, messages } from "./transport.ts";

export class Daemon {
  readonly process: Process;
  private writer: WritableStreamDefaultWriter<Uint8Array>;
  private sequence = 0;
  private saved: Message[] = [];
  private stopped?: Error;
  private reading: Promise<void>;
  private errors: Promise<void>;
  private stderr = "";
  private writes = Promise.resolve();
  private closed?: Promise<void>;
  private constructor(process: Process) {
    this.process = process;
    this.writer = this.process.stdin.getWriter();
    const stderr = this.process.stderr;
    this.errors = (async () => {
      for await (const chunk of stderr) {
        this.stderr += new TextDecoder().decode(chunk, { stream: true });
      }
    })();
    const stdout = this.process.stdout;
    this.reading = (async () => {
      try {
        for await (const message of messages(stdout)) this.saved.push(message);
        this.stopped = new Error("Daemon exited");
      } catch (error) {
        this.stopped = error instanceof Error
          ? error
          : new Error(String(error));
      }
    })();
  }
  static async create(
    binary: string,
    root: string,
    env: Record<string, string>,
  ) {
    const peer = new Daemon(
      await Process.spawn(binary, {
        args: ["--root", root, "--no-watch"],
        env,
      }),
    );
    try {
      await peer.call("initialize", { protocol: 4 });
      return peer;
    } catch (error) {
      await peer.close();
      throw error;
    }
  }
  async receive(predicate: (message: Message) => boolean, timeout = 10) {
    const deadline = now() + timeout;
    while (true) {
      const index = this.saved.findIndex(predicate);
      if (index >= 0) return this.saved.splice(index, 1)[0];
      if (this.stopped) {
        throw new Error(this.stopped.message + "\n" + this.stderr);
      }
      assert(now() < deadline, "Daemon message timed out");
      await sleep(0.005);
    }
  }
  // deno-lint-ignore no-explicit-any
  async call<T = any>(
    method: string,
    params: Record<string, unknown> = {},
    timeout = 10,
    error = false,
  ): Promise<T> {
    const id = ++this.sequence;
    this.writes = this.writes.then(() =>
      this.writer.write(frame({ jsonrpc: "2.0", id, method, params }))
    );
    await this.writes;
    const response = await this.receive(
      (message) => message.id === id,
      timeout,
    );
    assert(
      error ? response.error !== undefined : response.error === undefined,
      JSON.stringify(response),
    );
    assert(
      error || Object.hasOwn(response, "result"),
      "Missing JSON-RPC result",
    );
    return (error ? response.error : response.result) as T;
  }
  // deno-lint-ignore no-explicit-any
  async prepared<T = any>(
    job: string,
    timeout = 10,
    error = false,
  ): Promise<T> {
    const message = await this.receive(
      (m) =>
        ["pr/prepared", "pr/error"].includes(m.method ?? "") &&
        m.params?.job_id === job,
      timeout,
    );
    assert((message.method === "pr/error") === error, JSON.stringify(message));
    return message.params as T;
  }
  close() {
    return this.closed ??= (async () => {
      try {
        await this.writer.close();
      } catch { /* A killed worker cannot consume EOF. */ }
      try {
        await within(
          Promise.all([this.process.status, this.reading, this.errors]),
          5,
          "Daemon shutdown timed out",
        );
      } finally {
        this.process.terminate();
        this.process.destroyPipes();
        await Promise.allSettled([
          this.process.status,
          this.reading,
          this.errors,
        ]);
      }
    })();
  }
}

export interface Metadata {
  number: number;
  title: string;
  html_url: string;
  state: string;
  draft: boolean;
  merged: boolean;
  changed_files: number;
  base: {
    sha: string;
    ref: string;
    repo: { full_name: string; html_url: string };
  };
  head: { sha: string; ref: string; repo: { full_name: string } };
}
export async function fixture(
  root: string,
): Promise<[string, Metadata, Record<string, string>]> {
  const source = join(root, "source"),
    remote = join(root, "remote.git"),
    local = join(root, "local");
  mkdir(source);
  await git(source, "init", "-qb", "main");
  write(join(source, "file.txt"), "before\nsame\n");
  await git(source, "add", ".");
  await git(source, "commit", "-qm", "base");
  const base = await git(source, "rev-parse", "HEAD");
  await git(root, "clone", "-q", "--bare", source, remote);
  await git(root, "clone", "-q", remote, local);
  await git(source, "switch", "-qc", "topic");
  write(join(source, "file.txt"), "after\nsame\n");
  write(join(source, "new.txt"), "new file\n");
  await git(source, "add", ".");
  await git(source, "commit", "-qm", "topic");
  const head = await git(source, "rev-parse", "HEAD");
  await git(source, "push", "-q", remote, "HEAD:refs/pull/1/head");
  await git(
    local,
    "remote",
    "set-url",
    "origin",
    "https://github.com/example/project.git",
  );
  write(join(local, "file.txt"), "local draft on disk\nsame\n");
  write(join(local, ".git/FETCH_HEAD"), "preserve this file\n");
  const metadata: Metadata = {
    number: 1,
    title: "Example pull request",
    html_url: "https://github.com/example/project/pull/1",
    state: "open",
    draft: false,
    merged: false,
    changed_files: 2,
    base: {
      sha: base,
      ref: "main",
      repo: {
        full_name: "example/project",
        html_url: "https://github.com/example/project",
      },
    },
    head: {
      sha: head,
      ref: "topic",
      repo: { full_name: "contributor/project" },
    },
  };
  json(join(root, "metadata.json"), metadata);
  const bin = join(root, "bin");
  mkdir(bin);
  const realGit = executable("git");
  assert(realGit);
  const helper = [
    Deno.execPath(),
    "run",
    "--no-config",
    "-A",
    join(ROOT, "tests/fixture_command.ts"),
  ].map(shellQuote).join(" ");
  script(
    join(bin, "git"),
    `#!/bin/sh
set -eu
${helper} git-log "$$" "$@"
for arg do
  if [ "$arg" = fetch ]; then
    while [ -e "$DIFFREEL_PR_FIXTURE/hold-fetch" ]; do sleep 0.01; done
  fi
done
for arg do
  if [ "$arg" = https://github.com/example/project.git ]; then
    set -- "$@" "$DIFFREEL_PR_FIXTURE/remote.git"
  else
    set -- "$@" "$arg"
  fi
  shift
done
exec ${shellQuote(realGit)} "$@"
`,
  );
  script(join(bin, "gh"), `#!/bin/sh\nexec ${helper} gh "$@"\n`);
  return [local, metadata, {
    ...Deno.env.toObject(),
    PATH: bin + ":" + Deno.env.get("PATH"),
    DIFFREEL_PR_FIXTURE: root,
  }];
}
export async function unchanged_state(root: string) {
  return {
    head: await git(root, "rev-parse", "HEAD"),
    status: await git(root, "status", "--porcelain=v2"),
    index: bytes(join(root, ".git/index")),
    config: bytes(join(root, ".git/config")),
    fetch_head: bytes(join(root, ".git/FETCH_HEAD")),
    text: bytes(join(root, "file.txt")),
    refs: (await git(root, "for-each-ref", "--format=%(refname):%(objectname)"))
      .split("\n").filter((line) => !line.startsWith("refs/diffreel/pr/")).join(
        "\n",
      ),
  };
}
