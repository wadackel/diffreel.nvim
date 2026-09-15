import { assertEquals, assertRejects } from "@std/assert";
import { Nvim } from "./support.ts";
import { Random } from "./random.ts";

Deno.test("integer seeds preserve Python selection sequences", () => {
  const vectors = JSON.parse(
    Deno.readTextFileSync(new URL("fixtures/random.json", import.meta.url)),
  );
  for (const vector of vectors) {
    const random = new Random(vector.seed);
    assertEquals(
      Array.from({ length: 8 }, () => [1, 2, 3, 13, 40, 256, 257]).flat().map((
        n,
      ) => random.randrange(n)),
      vector.choices,
    );
    assertEquals(
      random.sample(Array.from({ length: 40 }, (_, i) => i), 40),
      vector.sample,
    );
  }
});

Deno.test("embedded Neovim handles concurrent replies, handles and UI flushes", async () => {
  const nvim = await Nvim.create(Deno.cwd());
  try {
    const frame = nvim.frames;
    const [buffer, value] = await Promise.all([
      nvim.request("nvim_get_current_buf"),
      nvim.lua("return {answer=42,items={1,2,3}}"),
    ]);
    assertEquals(typeof buffer, "number");
    assertEquals(value, { answer: 42, items: [1, 2, 3] });
    await nvim.request("nvim_command", "redraw!");
    await nvim.waitFrame(frame);
    assertEquals(nvim.text().includes("~"), true);
  } finally {
    await nvim.close();
  }
  assertEquals((await nvim.process.status).success, true);
});

Deno.test("editor close bounds stderr held by a reparented child", async () => {
  const nvim = await Nvim.create(Deno.cwd());
  await nvim.lua("local file=assert(io.popen('sleep 3 >&2 &'));file:close()");
  const started = performance.now();
  await assertRejects(() => nvim.close(), Error, "Neovim pipes remained open");
  assertEquals(performance.now() - started < 2500, true);
});

Deno.test("request timeout and editor exit reject outstanding requests", async () => {
  const nvim = await Nvim.create(Deno.cwd());
  try {
    await assertRejects(
      () =>
        nvim.requestWithTimeout("nvim_exec_lua", [
          "vim.wait(150);return true",
          [],
        ], 0.01),
      Error,
      "Timed out",
    );
    await nvim.lua("return true");
    const pending = nvim.request(
      "nvim_exec_lua",
      "vim.wait(10000);return true",
      [],
    );
    const rejected = assertRejects(() => pending, Error, "Neovim exited");
    nvim.process.kill("SIGKILL");
    await rejected;
  } finally {
    await nvim.close();
  }
});
