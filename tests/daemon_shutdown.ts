import {
  assert,
  denoArgs,
  join,
  mkdir,
  now,
  read,
  resolve,
  ROOT,
  run,
  script,
  shellQuote,
  temporary,
  terminate,
  wait,
} from "../scripts/lib.ts";
import { frame } from "./transport.ts";

if (Deno.args[0] === "helper") {
  Deno.writeTextFileSync(Deno.env.get("DIFFREEL_TEST_PIDFILE")! + ".ready", "");
  await new Promise((resolve) => setTimeout(resolve, 60000));
} else if (Deno.args[0] === "git") {
  Deno.writeTextFileSync(
    Deno.env.get("DIFFREEL_TEST_GIT_PIDFILE")!,
    String(Deno.pid),
  );
  const [command, ...args] = denoArgs("tests/daemon_shutdown.ts", "helper");
  const child = new Deno.Command(command, {
    args,
    stdin: "null",
    stdout: "null",
    stderr: "inherit",
  }).spawn();
  child.unref();
  Deno.writeTextFileSync(
    Deno.env.get("DIFFREEL_TEST_PIDFILE")!,
    String(child.pid),
  );
  Deno.stdout.writeSync(new TextEncoder().encode("# branch.oid (initial)\0"));
} else if (import.meta.main) {
  const binary = resolve(
    Deno.env.get("DIFFREEL_DAEMON") ??
      join(ROOT, "daemon/target/release/diffreel-daemon"),
  );
  using temp = temporary("diffreel-shutdown-");
  const root = temp.path;
  await run(["git", "init", "-q", root]);
  const bin = join(root, "bin");
  mkdir(bin);
  script(
    join(bin, "git"),
    "#!/bin/sh\nexec " +
      denoArgs("tests/daemon_shutdown.ts", "git").map(shellQuote).join(" ") +
      "\n",
  );
  const env = {
    ...Deno.env.toObject(),
    PATH: bin + ":" + Deno.env.get("PATH"),
    DIFFREEL_TEST_PIDFILE: join(root, "helper.pid"),
    DIFFREEL_TEST_GIT_PIDFILE: join(root, "git.pid"),
  };
  const daemon = new Deno.Command(binary, {
    args: ["--root", root, "--no-watch"],
    stdin: "piped",
    stdout: "piped",
    stderr: "piped",
    env,
  }).spawn();
  const output = daemon.output(), writer = daemon.stdin.getWriter();
  let helper: number | undefined, exited = false;
  try {
    await writer.write(
      frame({
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: { protocol: 4 },
      }),
    );
    await wait(
      async () => {
        try {
          helper = Number(read(join(root, "helper.pid")));
          const pid = Number(read(join(root, "git.pid")));
          if (!helper || !pid) return false;
          try {
            Deno.statSync(env.DIFFREEL_TEST_PIDFILE + ".ready");
          } catch (error) {
            if (error instanceof Deno.errors.NotFound) return false;
            throw error;
          }
          const state = await run(["ps", "-o", "stat=", "-p", String(pid)], {
            check: false,
          });
          return !state.success || state.stdout.trim().startsWith("Z");
        } catch (error) {
          if (error instanceof Deno.errors.NotFound) return false;
          throw error;
        }
      },
      5,
      "Fixture Git did not exit",
    );
    const started = now();
    daemon.kill("SIGTERM");
    const timer = setTimeout(() => {
      try {
        daemon.kill("SIGKILL");
      } catch { /* The process may finish as the timer fires. */ }
    }, 2000);
    try {
      const status = await daemon.status;
      assert(
        status.signal !== "SIGKILL",
        "Daemon shutdown exceeded two seconds",
      );
      exited = true;
    } finally {
      clearTimeout(timer);
    }
    console.log(
      JSON.stringify({ passed: true, stop_ms: (now() - started) * 1000 }),
    );
  } finally {
    if (!exited) {
      try {
        daemon.kill("SIGKILL");
      } catch { /* Initialization failure may already have stopped it. */ }
    }
    try {
      await writer.close();
    } catch { /* Shutdown closes the input pipe. */ }
    if (helper) terminate(helper, "SIGTERM");
    await output;
  }
}
