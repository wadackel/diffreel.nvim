import { toFileUrl } from "@std/path";
import { frame, messages } from "./transport.ts";

const [target, events] = Deno.args;
const writer = Deno.stdout.writable.getWriter();
try {
  for await (const message of messages(Deno.stdin.readable)) {
    Deno.writeTextFileSync(events, JSON.stringify(message) + "\n", {
      append: true,
    });
    if (message.method === "exit") break;
    if (message.id === undefined) continue;
    let result: unknown = null;
    if (message.method === "initialize") {
      result = {
        capabilities: {
          textDocumentSync: 1,
          hoverProvider: true,
          definitionProvider: true,
        },
      };
    } else if (message.method === "textDocument/hover") {
      result = {
        contents: { kind: "plaintext", value: "diffreel hover proof" },
      };
    } else if (message.method === "textDocument/definition") {
      result = {
        uri: toFileUrl(target).href,
        range: {
          start: { line: 0, character: 0 },
          end: { line: 0, character: 5 },
        },
      };
    }
    await writer.write(frame({ jsonrpc: "2.0", id: message.id, result }));
  }
} finally {
  writer.releaseLock();
}
