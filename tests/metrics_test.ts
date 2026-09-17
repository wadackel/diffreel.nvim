import { assert } from "@std/assert";
import {
  burn,
  calibrate,
  close,
  cpuSeconds,
  sample,
} from "../benchmarks/metrics.ts";
import { denoArgs, run } from "../scripts/lib.ts";

Deno.test({
  name: "macOS CPU clocks and reaped descendants preserve accounting",
  ignore: Deno.build.os !== "darwin",
  async fn() {
    try {
      const clock = await calibrate();
      let before = await sample(Deno.pid, clock);
      burn(0.05);
      let after = await sample(Deno.pid, clock);
      assert(
        after.cpu_ms - before.cpu_ms >= 45 &&
          after.cpu_ms - before.cpu_ms <= 250,
      );
      for (const seconds of [0.06, 0.4]) {
        before = await sample(Deno.pid, clock);
        const childrenBefore = cpuSeconds(-1);
        await run(denoArgs("benchmarks/metrics.ts", "--burn", String(seconds)));
        after = await sample(Deno.pid, clock);
        // Reading before the sample omits CPU spent in the sampler's own ps child.
        const expectedChildMs = (cpuSeconds(-1) - childrenBefore) * 1000;
        const accountedChildMs = after.processes.find((process) =>
          process.pid === Deno.pid
        )!.waited_child_cpu_ms -
          before.processes.find((process) => process.pid === Deno.pid)!
            .waited_child_cpu_ms;
        // A fixed ceiling conflates accounting errors with runtime startup cost.
        assert(
          expectedChildMs >= seconds * 1000 - 5 &&
            Math.abs(accountedChildMs - expectedChildMs) <=
              Math.max(10, expectedChildMs * 0.2),
          JSON.stringify({ expectedChildMs, accountedChildMs, before, after }),
        );
      }
      assert(after.rss_bytes > 0);
      const [command, ...args] = denoArgs("tests/metrics_fixture.ts", "parent");
      const parent = new Deno.Command(command, {
        args,
        stdin: "piped",
        stdout: "piped",
        stderr: "inherit",
      }).spawn();
      const writer = parent.stdin.getWriter(),
        reader = parent.stdout.getReader();
      try {
        assert(
          new TextDecoder().decode((await reader.read()).value).trim() ===
            "ready",
        );
        const alive = await sample(parent.pid, clock);
        const children = alive.processes.filter((process) =>
          process.pid !== parent.pid
        );
        assert(children.length === 1, JSON.stringify(alive));
        const childOwn = children[0].own_cpu_ms;
        await writer.write(new Uint8Array([120]));
        assert(
          new TextDecoder().decode((await reader.read()).value).trim() ===
            "waited",
        );
        const reaped = await sample(parent.pid, clock);
        const delta = reaped.cpu_ms - alive.cpu_ms;
        // A fixed ceiling fails on slow runners, where exit cost after the alive sample grows.
        assert(
          delta >= -(childOwn * 0.2) - 2 && delta <= childOwn * 0.5,
          JSON.stringify({ alive, reaped }),
        );
      } finally {
        await writer.write(new Uint8Array([120]));
        await writer.close();
        await parent.status;
        await reader.cancel();
        reader.releaseLock();
      }
      console.log(JSON.stringify({ passed: true, calibration: clock }));
    } finally {
      close();
    }
  },
});
