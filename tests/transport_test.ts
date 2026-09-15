import { assertEquals, assertRejects } from "@std/assert";
import { frame, messages } from "./transport.ts";

function chunks(data: Uint8Array, size: number) {
  return new ReadableStream<Uint8Array>({
    start(controller) {
      for (let i = 0; i < data.length; i += size) {
        controller.enqueue(data.slice(i, i + size));
      }
      controller.close();
    },
  });
}
Deno.test("JSON-RPC preserves split headers, UTF-8 bodies and coalesced messages", async () => {
  const values = [{ id: 1, result: "日本語🙂" }, {
      method: "ready",
      params: { token: "value" },
    }],
    parts = values.map(frame),
    data = new Uint8Array(parts[0].length + parts[1].length);
  data.set(parts[0]);
  data.set(parts[1], parts[0].length);
  for (const size of [1, 3, 11, data.length]) {
    assertEquals(await Array.fromAsync(messages(chunks(data, size))), values);
  }
});
Deno.test("truncated and malformed JSON-RPC streams fail", async () => {
  await assertRejects(
    () =>
      Array.fromAsync(
        messages(chunks(frame({ id: 1, result: true }).slice(0, -1), 2)),
      ),
    Error,
    "Truncated",
  );
  await assertRejects(
    () =>
      Array.fromAsync(
        messages(
          chunks(new TextEncoder().encode("Content-Length: nope\r\n\r\n{}"), 2),
        ),
      ),
    Error,
    "Content-Length",
  );
});
