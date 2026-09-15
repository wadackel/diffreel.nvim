import { frame, messages } from "./transport.ts";

const writer = Deno.stdout.writable.getWriter();
for await (const message of messages(Deno.stdin.readable)) {
  if (message.method === "hold") setInterval(() => {}, 1000);
  await writer.write(
    frame(
      message.method === "missing"
        ? { jsonrpc: "2.0", id: message.id }
        : { jsonrpc: "2.0", id: message.id, result: null },
    ),
  );
}
writer.releaseLock();
