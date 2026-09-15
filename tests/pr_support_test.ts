import { assertEquals, assertRejects } from "@std/assert";
import { Daemon } from "./pr_support.ts";
import {
  denoArgs,
  join,
  script,
  shellQuote,
  temporary,
} from "../scripts/lib.ts";

Deno.test("daemon calls reject missing results and preserve null results", async () => {
  using temp = temporary("daemon-transport-");
  const executable = join(temp.path, "daemon");
  script(
    executable,
    "#!/bin/sh\nexec " +
      denoArgs("tests/pr_transport_fixture.ts").map(shellQuote).join(" ") +
      "\n",
  );
  const peer = await Daemon.create(executable, temp.path, Deno.env.toObject());
  try {
    assertEquals(await peer.call("null"), null);
    await assertRejects(
      () => peer.call("missing"),
      Error,
      "Missing JSON-RPC result",
    );
  } finally {
    await peer.close();
  }
});
Deno.test("EOF shutdown deadline fails after cleaning up a stuck daemon", async () => {
  using temp = temporary("daemon-shutdown-");
  const executable = join(temp.path, "daemon");
  script(
    executable,
    "#!/bin/sh\nexec " +
      denoArgs("tests/pr_transport_fixture.ts").map(shellQuote).join(" ") +
      "\n",
  );
  const peer = await Daemon.create(executable, temp.path, Deno.env.toObject());
  await peer.call("hold");
  await assertRejects(() => peer.close(), Error, "Daemon shutdown timed out");
  assertEquals((await peer.process.status).signal, "SIGKILL");
});
