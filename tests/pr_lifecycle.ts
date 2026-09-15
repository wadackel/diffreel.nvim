import { Daemon, fixture, unchanged_state } from "./pr_support.ts";
import {
  assert,
  assertEquals,
  exists,
  git,
  join,
  mkdir,
  read,
  remove,
  resolve,
  run,
  temporary,
  wait,
  write,
} from "../scripts/lib.ts";

async function running(pid: number) {
  const result = await run(["ps", "-o", "stat=", "-p", String(pid)], {
    check: false,
  });
  return result.success && !result.stdout.trim().startsWith("Z");
}
async function main() {
  const binary = resolve(Deno.env.get("DIFFREEL_DAEMON")!),
    output = ".wadackel/qa/2026-09-14-pr-fetch/lifecycle";
  mkdir(output);
  const cases = [];
  for (
    const action of [
      "cancel",
      "daemon-kill",
      "worker-kill",
      "concurrent",
      "linked-worktree",
    ]
  ) {
    console.log(JSON.stringify({ case: action }));
    using temp = temporary("lifecycle-", output);
    const folder = temp.path;
    const [root, _metadata, env] = await fixture(folder);
    let peer = root;
    if (action === "linked-worktree") {
      peer = join(folder, "linked");
      await git(root, "worktree", "add", "--detach", peer, "HEAD");
    }
    const before = await unchanged_state(root),
      first = await Daemon.create(binary, root, env);
    let second: Daemon | undefined, pid: number | undefined;
    try {
      second = await Daemon.create(binary, peer, env);
      write(join(folder, "hold-fetch"), "");
      const accepted = await first.call("pr/prepare", {
        view_id: "one",
        pr: 1,
      });
      await wait(() =>
        ["fetch.pid", "worker.pid"].every((name) =>
          exists(join(folder, name)) &&
          /^[1-9]\d*$/.test(read(join(folder, name)).trim())
        )
      );
      pid = Number(read(join(folder, "fetch.pid")));
      const worker = Number(read(join(folder, "worker.pid")));
      await second.call("pr/cache-clear", {}, 10, true);
      if (action === "cancel") {
        await first.call("pr/cancel", { job_id: accepted.job_id });
        await first.call("pr/release", { view_id: "one" });
        await wait(async () => !(await running(pid!)));
      } else if (action === "daemon-kill") {
        first.process.kill("SIGKILL");
        await first.process.status;
        await wait(async () =>
          !(await running(pid!)) && !(await running(worker))
        );
      } else if (action === "worker-kill") {
        Deno.kill(worker, "SIGKILL");
        await first.prepared(accepted.job_id, 10, true);
        await first.call("pr/release", { view_id: "one" });
        assert(
          await running(pid),
          "Mutating child exited before lock-inheritance probe",
        );
        await second.call("pr/cache-clear", {}, 10, true);
        remove(join(folder, "hold-fetch"));
        await wait(async () => !(await running(pid!)));
      } else {
        const other = await second.call("pr/prepare", {
          view_id: "two",
          pr: 1,
        });
        remove(join(folder, "hold-fetch"));
        await first.prepared(accepted.job_id);
        await second.prepared(other.job_id);
        await first.call("pr/release", { view_id: "one" });
        await first.call("pr/cache-clear", {}, 10, true);
        await second.call("pr/release", { view_id: "two" });
      }
      await wait(async () => !(await running(worker)));
      await second.call("pr/cache-clear");
      assertEquals(await unchanged_state(root), before);
      cases.push(action);
    } finally {
      remove(join(folder, "hold-fetch"));
      await first.close();
      await second?.close();
      if (pid && await running(pid)) Deno.kill(pid, "SIGKILL");
    }
  }
  console.log(JSON.stringify({ passed: true, cases }));
}
if (import.meta.main) await main();
