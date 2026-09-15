import { assert, decoder, encoder } from "../scripts/lib.ts";

export interface Message {
  jsonrpc?: string;
  id?: number | string;
  method?: string;
  params?: Record<string, unknown>;
  result?: unknown;
  error?: unknown;
}
export function frame(message: Message) {
  const body = encoder.encode(JSON.stringify(message)),
    header = encoder.encode(`Content-Length: ${body.length}\r\n\r\n`);
  const result = new Uint8Array(header.length + body.length);
  result.set(header);
  result.set(body, header.length);
  return result;
}
export async function* messages(
  stream: ReadableStream<Uint8Array>,
): AsyncGenerator<Message> {
  let buffer = new Uint8Array(0), length: number | undefined;
  for await (const chunk of stream) {
    const joined = new Uint8Array(buffer.length + chunk.length);
    joined.set(buffer);
    joined.set(chunk, buffer.length);
    buffer = joined;
    while (buffer.length) {
      if (length === undefined) {
        let boundary = -1;
        for (let i = 0; i + 3 < buffer.length; i++) {
          if (
            buffer[i] === 13 && buffer[i + 1] === 10 && buffer[i + 2] === 13 &&
            buffer[i + 3] === 10
          ) {
            boundary = i;
            break;
          }
        }
        if (boundary < 0) break;
        const match = decoder.decode(buffer.subarray(0, boundary)).match(
          /^Content-Length:\s*(\d+)\s*$/im,
        );
        assert(match, "Missing Content-Length");
        length = Number(match[1]);
        assert(
          Number.isSafeInteger(length) && length > 0,
          "Invalid Content-Length",
        );
        buffer = buffer.slice(boundary + 4);
      }
      if (buffer.length < length) break;
      const value = JSON.parse(decoder.decode(buffer.subarray(0, length)));
      assert(
        value && typeof value === "object" && !Array.isArray(value),
        "Invalid JSON-RPC message",
      );
      buffer = buffer.slice(length);
      length = undefined;
      yield value;
    }
  }
  assert(
    buffer.length === 0 && length === undefined,
    "Truncated JSON-RPC message",
  );
}
