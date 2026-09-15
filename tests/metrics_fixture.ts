import { burn, close } from "../benchmarks/metrics.ts";
import { denoArgs } from "../scripts/lib.ts";

async function input() {
  await Deno.stdin.read(new Uint8Array(1));
}
if (Deno.args[0] === "child") {
  try {
    burn(0.08);
    console.log("ready");
    await input();
  } finally {
    close();
  }
} else {
  const [command, ...args] = denoArgs("tests/metrics_fixture.ts", "child");
  const child = new Deno.Command(command, {
    args,
    stdin: "piped",
    stdout: "piped",
    stderr: "inherit",
  }).spawn();
  const reader = child.stdout.getReader(), writer = child.stdin.getWriter();
  try {
    await reader.read();
    console.log("ready");
    await input();
    await writer.write(new Uint8Array([120]));
    await writer.close();
    await child.status;
    console.log("waited");
    await input();
  } finally {
    await reader.cancel();
    reader.releaseLock();
  }
}
